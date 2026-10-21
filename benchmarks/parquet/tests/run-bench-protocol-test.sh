#!/usr/bin/env bash
# Protocol self-test for benchmarks/parquet/run-bench.sh (negative-first).
#
# run-bench.sh is sourceable (its executable flow sits behind a source
# guard), so this test drives its REAL ensure_fixture/write_manifest with a
# stubbed generator tool and scratch directories — no benchmark runs, no
# real datasets. The cases pin the invariants an earlier version broke:
#   * fixture identity binds to the FROZEN r1 record committed to the repo,
#     never to the sidecar the generator writes next to the dataset — a
#     dataset that drifts together with its sidecar must regenerate, and a
#     generator whose output misses the frozen record fails the protocol;
#   * the manifest records the exact build artifacts (three executables, the
#     staged Sluice libraries) and refuses to exist if any of them is
#     missing, and each admitted result appends its digest to it;
#   * the manifest is written only after every selected dataset exists, so
#     an empty build can never produce a manifest without its DATASET lines.
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export STUB_LOG="$tmp/stub.log"

# Source the real script; its top level only resolves repo paths, the flow
# is in main() behind the source guard.
# shellcheck source=../../run-bench.sh
source "$repo/benchmarks/parquet/run-bench.sh"

# Redirect the protocol onto scratch state.
data_dir="$tmp/data"
results_dir="$tmp/results"
frozen_dir="$tmp/frozen"
build_dir="$tmp/build"
sdk_prefix="$tmp/sdk"
fixture="$tmp/stub-fixture"
tracer="$build_dir/experiments/parquet/parquet_trace"
bench="$build_dir/experiments/parquet/parquet_bench"
mkdir -p "$data_dir" "$results_dir" "$frozen_dir" \
    "$build_dir/experiments/parquet" "$sdk_prefix/lib"

fails=0
cases=0
fail_now() {
    echo "FAIL: $*" >&2
    fails=$((fails + 1))
}
check() { # <label> <condition...>
    cases=$((cases + 1))
    if ! eval "$2"; then
        fail_now "$1"
    fi
}

cat > "$fixture" <<'STUB'
#!/usr/bin/env bash
echo "invoked: $*" >> "$STUB_LOG"
if [[ "${STUB_FAIL:-0}" == 1 ]]; then
    exit 1
fi
out="" dataset="" codec=none
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) out="$2"; shift 2 ;;
        --dataset) dataset="$2"; shift 2 ;;
        --compression) codec="$2"; shift 2 ;;
        *) exit 2 ;;
    esac
done
payload="canonical-$dataset-payload-v1"
file="$out/$dataset-$codec.parquet"
printf '%s' "$payload" > "$file"
sha=$(sha256sum "$file" | awk '{print $1}')
printf '{"sha256":"%s"}\n' "$sha" > "$out/manifest-$dataset-$codec.json"
STUB
chmod +x "$fixture"

invocations() {
    [[ -f "$STUB_LOG" ]] && wc -l < "$STUB_LOG" || echo 0
}
canonical() { # <name>
    printf 'canonical-%s-payload-v1' "$1"
}
freeze() { # <name> — the frozen r1 record for the stub's canonical payload
    local name="$1" payload
    payload=$(canonical "$name")
    printf '{"dataset":"%s","compression":"none","bytes":%d,"sha256":"%s"}\n' \
        "$name" "${#payload}" \
        "$(printf '%s' "$payload" | sha256sum | awk '{print $1}')" \
        > "$frozen_dir/manifest-$name-none.json"
}
freeze small
freeze medium

# --- identity admission ------------------------------------------------------
if ensure_fixture small; then
    check "fresh generation produces the canonical dataset" \
        '[[ "$(cat "$data_dir/small-none.parquet")" == "$(canonical small)" ]]'
    check "fresh generation invoked the generator once" '[[ "$(invocations)" == 1 ]]'
else
    check "ensure_fixture succeeds on a fresh dataset" 'false'
fi

if ensure_fixture small; then
    check "verified reuse does not regenerate" '[[ "$(invocations)" == 1 ]]'
else
    check "ensure_fixture succeeds on a verified dataset" 'false'
fi

printf 'garbage-appended' >> "$data_dir/small-none.parquet"
if ensure_fixture small; then
    check "corrupted dataset is detected and regenerated" \
        '[[ "$(cat "$data_dir/small-none.parquet")" == "$(canonical small)" ]]'
    check "corruption triggered exactly one regeneration" '[[ "$(invocations)" == 2 ]]'
else
    check "ensure_fixture succeeds over a corrupted dataset" 'false'
fi

# A dataset that drifts together with its sidecar stays self-consistent; the
# frozen record is what exposes it. A sidecar-trusting implementation passes
# exactly this shape.
printf 'drifted' >> "$data_dir/small-none.parquet"
drift_sha=$(sha256sum "$data_dir/small-none.parquet" | awk '{print $1}')
printf '{"sha256":"%s"}\n' "$drift_sha" > "$data_dir/manifest-small-none.json"
if ensure_fixture small; then
    check "sidecar-consistent drift is regenerated" \
        '[[ "$(cat "$data_dir/small-none.parquet")" == "$(canonical small)" ]]'
    check "drift triggered exactly one regeneration" '[[ "$(invocations)" == 3 ]]'
else
    check "ensure_fixture succeeds over sidecar-consistent drift" 'false'
fi

# With the frozen record as the authority, a missing sidecar no longer forces
# regeneration: bytes matching the frozen record are the frozen dataset.
rm "$data_dir/manifest-small-none.json"
if ensure_fixture small; then
    check "frozen-matching dataset reuses without its sidecar" '[[ "$(invocations)" == 3 ]]'
else
    check "ensure_fixture succeeds over a record-less dataset" 'false'
fi

# --- frozen-record and generator failures propagate ----------------------------
mv "$frozen_dir/manifest-medium-none.json" "$tmp/frozen-medium.bak"
if ensure_fixture medium 2>/dev/null; then
    check "missing frozen record fails the protocol" 'false'
else
    check "missing frozen record fails the protocol" 'true'
fi
mv "$tmp/frozen-medium.bak" "$frozen_dir/manifest-medium-none.json"

export STUB_FAIL=1
if ensure_fixture medium 2>/dev/null; then
    check "generator failure fails the protocol" 'false'
else
    check "generator failure fails the protocol" 'true'
fi
export STUB_FAIL=0

# The generator produced bytes, but they are not the frozen dataset: a hard
# failure, never a silent substitution of the measured data.
printf '{"dataset":"medium","compression":"none","bytes":24,"sha256":"%s"}\n' \
    "$(printf 'not-the-canonical-medium' | sha256sum | awk '{print $1}')" \
    > "$frozen_dir/manifest-medium-none.json"
if ensure_fixture medium 2>/dev/null; then
    check "generator output missing the frozen record is rejected" 'false'
else
    check "generator output missing the frozen record is rejected" 'true'
fi
freeze medium

# Re-add a proper medium fixture for the manifest cases.
rm -f "$data_dir"/medium-none.parquet "$data_dir"/manifest-medium-none.json
ensure_fixture medium >/dev/null

# --- build-artifact provenance ------------------------------------------------
: > "$build_dir/experiments/parquet/parquet_fixture"
: > "$build_dir/experiments/parquet/parquet_trace"
: > "$build_dir/experiments/parquet/parquet_bench"
chmod +x "$build_dir"/experiments/parquet/parquet_{fixture,trace,bench}
: > "$sdk_prefix/lib/libsluice_core.a"
: > "$sdk_prefix/lib/libsluice_async.a"

mv "$bench" "$tmp/bench.bak"
if require_binaries 2>/dev/null; then
    check "missing executable fails the binary check" 'false'
else
    check "missing executable fails the binary check" 'true'
fi
mv "$tmp/bench.bak" "$bench"
check "complete executables pass the binary check" 'require_binaries'

# --- manifest completeness (the empty-build regression) ----------------------
# The selected dataset is absent (the empty-build state): refusing is the
# behavior under test; the pre-fix script would have emitted the manifest
# with the DATASET line silently omitted.
rm "$data_dir/small-none.parquet"
rm -rf "$results_dir"
mkdir -p "$results_dir"
if write_manifest small 2>/dev/null; then
    check "manifest refuses a selected-but-missing dataset" 'false'
else
    check "manifest refuses a selected-but-missing dataset" 'true'
fi
check "refused manifest writes no partial file" '[[ ! -f "$results_dir/run-manifest.txt" ]]'

if write_manifest 2>/dev/null; then
    check "manifest refuses an empty selection" 'false'
else
    check "manifest refuses an empty selection" 'true'
fi

ensure_fixture small >/dev/null # restore for the green case
printf 'trace-line\n' > "$results_dir/trace-medium-t3.jsonl"
if write_manifest small medium; then
    manifest="$results_dir/run-manifest.txt"
    small_sha=$(sha256sum "$data_dir/small-none.parquet" | awk '{print $1}')
    check "manifest records both datasets" \
        '[[ "$(grep -c "^DATASET " "$manifest")" == 2 ]]'
    check "manifest dataset digest matches the file" \
        "grep -q \"DATASET .*/small-none.parquet $small_sha \" \"\$manifest\""
    check "manifest records the trace artifact" \
        '[[ "$(grep -c "^TRACE " "$manifest")" == 1 ]]'
    check "manifest records the three build executables" \
        '[[ "$(grep -c "^BINARY " "$manifest")" == 3 ]]'
    check "manifest records the staged sluice libraries" \
        '[[ "$(grep -c "^LIB " "$manifest")" == 2 ]]'
    bench_sha=$(sha256sum "$bench" | awk '{print $1}')
    check "manifest binary digest matches the executable" \
        "grep -q \"BINARY .*parquet_bench $bench_sha \" \"\$manifest\""
else
    check "manifest succeeds with verified datasets and artifacts" 'false'
fi

# --- admitted results extend the manifest -------------------------------------
printf '{"benchmarks":[]}\n' > "$results_dir/measure-pass.json"
result_sha=$(sha256sum "$results_dir/measure-pass.json" | awk '{print $1}')
if record_result "$results_dir/measure-pass.json"; then
    check "admitted result appends its digest to the manifest" \
        "grep -q \"RESULT .*/measure-pass.json $result_sha \" \"\$results_dir/run-manifest.txt\""
else
    check "record_result succeeds on an admitted result" 'false'
fi
if record_result "$results_dir/no-such.json" 2>/dev/null; then
    check "record_result refuses a missing result" 'false'
else
    check "record_result refuses a missing result" 'true'
fi

# A manifest naming a build artifact that is not there must refuse, never
# emit a receipt with the artifact line silently omitted.
mv "$sdk_prefix/lib/libsluice_core.a" "$tmp/lib-core.bak"
rm -rf "$results_dir"
mkdir -p "$results_dir"
if write_manifest small medium 2>/dev/null; then
    check "manifest refuses a missing build artifact" 'false'
else
    check "manifest refuses a missing build artifact" 'true'
fi
check "refused manifest writes no partial file (build artifact)" \
    '[[ ! -f "$results_dir/run-manifest.txt" ]]'
mv "$tmp/lib-core.bak" "$sdk_prefix/lib/libsluice_core.a"

if [[ $fails -ne 0 ]]; then
    echo "run-bench-protocol-test: $fails failure(s) over $cases checks" >&2
    exit 1
fi
echo "run-bench-protocol-test: PASS ($cases checks, negative-first)"

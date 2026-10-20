#!/usr/bin/env bash
# Protocol self-test for benchmarks/parquet/run-bench.sh (negative-first).
#
# run-bench.sh is sourceable (its executable flow sits behind a source
# guard), so this test drives its REAL ensure_fixture/write_manifest with a
# stubbed generator tool and scratch directories — no benchmark runs, no
# real datasets. The cases pin the two invariants an earlier version broke:
#   * a dataset is admitted by identity (sidecar sha match), never by file
#     existence — a corrupted or record-less dataset must regenerate, and a
#     generator whose output fails its own record must fail the protocol;
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
fixture="$tmp/stub-fixture"
mkdir -p "$data_dir" "$results_dir"

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
if [[ "${STUB_BADSHA:-0}" == 1 ]]; then
    sha="deadbeef"
else
    sha=$(sha256sum "$file" | awk '{print $1}')
fi
printf '{"sha256":"%s"}\n' "$sha" > "$out/manifest-$dataset-$codec.json"
STUB
chmod +x "$fixture"

invocations() {
    [[ -f "$STUB_LOG" ]] && wc -l < "$STUB_LOG" || echo 0
}
canonical() { # <name>
    printf 'canonical-%s-payload-v1' "$1"
}

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

rm "$data_dir/manifest-small-none.json"
if ensure_fixture small; then
    check "missing identity record forces regeneration" \
        '[[ "$(cat "$data_dir/small-none.parquet")" == "$(canonical small)" && "$(invocations)" == 3 ]]'
else
    check "ensure_fixture succeeds over a record-less dataset" 'false'
fi

# --- generator failures propagate --------------------------------------------
export STUB_FAIL=1
if ensure_fixture medium 2>/dev/null; then
    check "generator failure fails the protocol" 'false'
else
    check "generator failure fails the protocol" 'true'
fi
export STUB_FAIL=0

export STUB_BADSHA=1
if ensure_fixture medium 2>/dev/null; then
    check "output that fails its own record is rejected" 'false'
else
    check "output that fails its own record is rejected" 'true'
fi
export STUB_BADSHA=0

# Re-add a proper medium fixture for the manifest cases.
rm -f "$data_dir"/medium-none.parquet "$data_dir"/manifest-medium-none.json
ensure_fixture medium >/dev/null

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
else
    check "manifest succeeds with verified datasets" 'false'
fi

if [[ $fails -ne 0 ]]; then
    echo "run-bench-protocol-test: $fails failure(s) over $cases checks" >&2
    exit 1
fi
echo "run-bench-protocol-test: PASS ($cases checks, negative-first)"

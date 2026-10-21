#!/usr/bin/env bash
# Formal standalone Parquet benchmark protocol (R1).
#
#   bash benchmarks/parquet/run-bench.sh [small|medium|both]
#
# What it does, in order:
#   1. rebuilds the protocol tools (fixture, tracer, bench) so the build
#      system proves the binaries belong to this tree — a stale executable
#      from an earlier checkout would be measured while the manifest
#      records the newer SHA (untimed);
#   2. builds the fixture datasets, or verifies an existing one against the
#      frozen r1 record committed to the repo (digest, size, labels); a
#      sidecar-consistent dataset that drifted off the frozen record
#      regenerates, and generation/verification are never timed;
#   3. captures the I/O request trace from diagnostic P1 and P2 runs
#      (untimed) and validates both structurally (validate-trace.sh);
#   4. writes the provenance manifest — only after the artifacts it names
#      exist and verify, so a fresh checkout can never record a manifest
#      without its dataset, binary and library lines;
#   5. runs pass 1 as cache warm-up (results kept for reference only);
#   6. runs pass 2, the sampled pass: Google Benchmark with
#      --benchmark_repetitions=$REPS independent samples per benchmark,
#      arms registered interleaved per workload (P0,P1,P2 back-to-back);
#      every pass is admitted by validate-results.sh before it counts, and
#      each admitted JSON appends its digest to the manifest, closing the
#      chain from the numbers to the raw evidence;
#   7. writes raw JSON to build/parquet-results/ and a human summary next
#      to it.
#
# Cache protocol: warm OS page cache only. Nothing here drops caches; the
# first pass exists so the second pass never pays a cold-cache tax.
#
# The self-test (tests/run-bench-protocol-test.sh) sources this file and
# drives ensure_fixture/write_manifest with stubbed tool paths; that is why
# the executable flow lives in main() behind the source guard below.
set -euo pipefail

REPS="${DUDUDU_BENCH_REPS:-10}"
WARMUP_SECONDS="${DUDUDU_BENCH_WARMUP_S:-2}"

repo=$(git rev-parse --show-toplevel)
cd "$repo"
build_dir=build/cmake-parquet
data_dir=build/parquet-data
results_dir=build/parquet-results
frozen_dir=benchmarks/parquet/results/r1
sdk_prefix=build/sluice-sdk/noliburing
bench_targets=(parquet_fixture parquet_trace parquet_bench)
fixture="$build_dir/experiments/parquet/parquet_fixture"
tracer="$build_dir/experiments/parquet/parquet_trace"
bench="$build_dir/experiments/parquet/parquet_bench"

# Build provenance: the manifest names a code SHA, so the protocol may only
# run binaries the build system just verified against this tree. Rebuilding
# first makes a stale executable from an earlier checkout either recompile
# or stop the run; the digests recorded in the manifest then pin exactly
# which bytes were measured.
verify_binaries() {
    echo "== build verification (untimed)"
    cmake --build "$build_dir" --target "${bench_targets[@]}" --parallel 4 \
        || { echo "run-bench: build verification failed for ${bench_targets[*]}" >&2; return 1; }
    require_binaries
}

require_binaries() {
    local f
    for f in "$fixture" "$tracer" "$bench"; do
        if [[ ! -x "$f" ]]; then
            echo "run-bench: missing executable after build: $f (configure with: cmake --preset parquet)" >&2
            return 1
        fi
    done
}

# Fixture identity binds to the frozen r1 record committed under
# benchmarks/parquet/results/r1/ — never to the sidecar sitting next to the
# dataset. Dataset and sidecar both live under mutable build/, so a dataset
# whose bytes drifted together with its sidecar would pass a self-referential
# check while no longer being the data R1's evidence was generated from.
# Digest, byte size and the frozen record's own labels must all match;
# anything else regenerates once, and a regenerated dataset that still misses
# the frozen record is a hard error (generator or toolchain drift — R1's
# fixtures are pinned to the Arrow version the record names).
ensure_fixture() { # <name>
    local name="$1"
    local file="$data_dir/$name-none.parquet"
    local frozen="$frozen_dir/manifest-$name-none.json"
    local want have want_bytes
    if [[ ! -f "$frozen" ]]; then
        echo "run-bench: no frozen identity record for $name: $frozen" >&2
        return 1
    fi
    if [[ "$(jq -r '.dataset // empty' "$frozen")" != "$name" \
        || "$(jq -r '.compression // empty' "$frozen")" != "none" ]]; then
        echo "run-bench: frozen record $frozen is not for dataset $name/none" >&2
        return 1
    fi
    want=$(jq -r '.sha256 // empty' "$frozen")
    want_bytes=$(jq -r '.bytes // empty' "$frozen")
    if [[ -z "$want" || -z "$want_bytes" ]]; then
        echo "run-bench: frozen record $frozen lacks sha256/bytes" >&2
        return 1
    fi
    local verified=0
    if [[ -f "$file" ]]; then
        have=$(sha256sum "$file" | awk '{print $1}')
        if [[ "$have" == "$want" && "$(stat -c%s "$file")" == "$want_bytes" ]]; then
            verified=1
        else
            echo "== $name fixture deviates from the frozen r1 record (frozen=$want have=$have); regenerating"
        fi
    fi
    if [[ "$verified" -eq 0 ]]; then
        echo "== generating $name fixture (not timed)"
        "$fixture" --out "$data_dir" --dataset "$name" --compression none \
            || { echo "run-bench: fixture generation failed: $name" >&2; return 1; }
        have=$(sha256sum "$file" | awk '{print $1}')
        if [[ "$have" != "$want" || "$(stat -c%s "$file")" != "$want_bytes" ]]; then
            echo "run-bench: regenerated $name fixture misses the frozen r1 record (frozen=$want have=$have)" >&2
            return 1
        fi
    fi
}

artifact_line() { # <tag> <file> -> "<TAG> <path> <sha256> <bytes>", fail if absent
    local tag="$1" f="$2"
    if [[ ! -f "$f" ]]; then
        echo "run-bench: manifest cannot record a missing artifact: $f" >&2
        return 1
    fi
    echo "$tag $f $(sha256sum "$f" | awk '{print $1}') $(stat -c%s "$f")"
}

dataset_line() { artifact_line DATASET "$1"; }

trace_line() { # <file> -> "TRACE <path> <sha256> <lines>"
    local f="$1"
    if [[ ! -f "$f" ]]; then
        echo "run-bench: manifest cannot record a missing artifact: $f" >&2
        return 1
    fi
    echo "TRACE $f $(sha256sum "$f" | awk '{print $1}') $(wc -l < "$f")"
}

# An admitted pass appends its raw JSON digest to the manifest, so the
# receipt chain runs code SHA -> binaries -> datasets -> traces -> the exact
# JSON the summary was computed from. Nothing appends on a rejected pass.
record_result() { # <json>
    local f="$1"
    if [[ ! -f "$f" ]]; then
        echo "run-bench: cannot record a missing result: $f" >&2
        return 1
    fi
    artifact_line RESULT "$f" >> "$results_dir/run-manifest.txt"
}

# Provenance manifest (AGENTS rule 1 / matrix rule 4): every result set
# carries both SHAs, the SDK identity, the identities of the exact binaries
# and staged Sluice libraries that ran, the sampling parameters, the host
# and the digests of every artifact the numbers depend on. Called only
# after the datasets exist and verify (and the tools were rebuilt); a
# selected dataset or build artifact that cannot be recorded is a hard
# failure, never a silently incomplete manifest.
write_manifest() { # <selected-datasets...>
    if [[ "$#" -eq 0 ]]; then
        echo "run-bench: refusing to write a manifest for no datasets" >&2
        return 1
    fi
    local name
    for name in "$@"; do
        if [[ ! -f "$data_dir/$name-none.parquet" ]]; then
            echo "run-bench: manifest cannot record a missing dataset: $name" >&2
            return 1
        fi
    done
    local bins=("$fixture" "$tracer" "$bench")
    local libs=("$sdk_prefix/lib/libsluice_core.a" "$sdk_prefix/lib/libsluice_async.a")
    local f
    for f in "${bins[@]}" "${libs[@]}"; do
        if [[ ! -f "$f" ]]; then
            echo "run-bench: manifest cannot record a missing build artifact: $f" >&2
            return 1
        fi
    done
    mkdir -p "$results_dir"
    local dududu_sha sluice_sha
    dududu_sha=$(git rev-parse HEAD)
    sluice_sha=$(git -C third_party/sluice rev-parse HEAD)
    {
        echo "DUDUDU_SHA=$dududu_sha"
        echo "SLUICE_SHA=$sluice_sha"
        echo "SLUICE_PROFILE=noliburing"
        echo "SDK_PREFIX=$sdk_prefix"
        echo "ARROW_VERSION=$(pkg-config --modversion arrow 2>/dev/null || echo unknown)"
        echo "PARQUET_VERSION=$(pkg-config --modversion parquet 2>/dev/null || echo unknown)"
        echo "REPS=$REPS"
        echo "WARMUP_SECONDS=$WARMUP_SECONDS"
        echo "KERNEL=$(uname -r)"
        echo "DATE_UTC=$(date -u +%FT%TZ)"
        echo "COMPILER=$(g++ -dumpversion)"
        for f in "${bins[@]}"; do
            artifact_line BINARY "$f"
        done
        for f in "${libs[@]}"; do
            artifact_line LIB "$f"
        done
        local name
        for name in "$@"; do
            dataset_line "$data_dir/$name-none.parquet"
        done
        local t
        for t in "$results_dir"/trace-medium-t3.jsonl "$results_dir"/trace-medium-t3-p2.jsonl; do
            if [[ -f "$t" ]]; then
                trace_line "$t"
            fi
        done
    } > "$results_dir/run-manifest.txt"
}

run_pass() { # pass-name — validated against the full roster before it counts
    local pass="$1"
    local args=()
    if [[ -f "$data_dir/small-none.parquet" ]]; then
        args+=(--small="$data_dir/small-none.parquet")
    fi
    if [[ -f "$data_dir/medium-none.parquet" ]]; then
        args+=(--medium="$data_dir/medium-none.parquet")
    fi
    if [[ -f "$results_dir/trace-medium-t3.jsonl" ]]; then
        args+=(--trace="$results_dir/trace-medium-t3.jsonl")
    fi
    local json="$results_dir/$pass.json"
    local log="$results_dir/$pass.log"
    echo "== $pass -> $json"
    # Console output (dataset identities, GB progress, any SkipWithError) is
    # evidence too; it lands in the log next to the JSON.
    "$bench" "${args[@]}" \
        --benchmark_repetitions="$REPS" \
        --benchmark_min_warmup_time="$WARMUP_SECONDS" \
        --benchmark_format=json \
        --benchmark_out="$json" > "$log" 2>&1
    grep -E "^# dataset|SkipWithError|error" "$log" || true
    # Fail closed: a pass is only usable if the exact expected roster ran
    # with $REPS clean samples each. A partial or errored JSON (missing arm,
    # SkipWithError, short sampling) aborts the protocol here and never
    # reaches the summary.
    local trace_args=()
    [[ -f "$results_dir/trace-medium-t3.jsonl" ]] && trace_args=(--trace)
    bash benchmarks/parquet/validate-results.sh "$json" "$selected" "$REPS" "${trace_args[@]}"
    record_result "$json"
}

main() {
    local selected="${1:-both}"
    [[ "$selected" == "small" || "$selected" == "medium" || "$selected" == "both" ]] || {
        echo "usage: run-bench.sh [small|medium|both]" >&2
        exit 2
    }
    mkdir -p "$data_dir" "$results_dir"

    # The tools must provably belong to this tree before anything runs.
    verify_binaries

    local names=()
    [[ "$selected" == "small" || "$selected" == "both" ]] && names+=(small)
    [[ "$selected" == "medium" || "$selected" == "both" ]] && names+=(medium)
    local name
    for name in "${names[@]}"; do
        ensure_fixture "$name"
    done

    local trace_args=()
    if [[ "$selected" == "medium" || "$selected" == "both" ]]; then
        echo "== capturing I/O trace (diagnostic, untimed)"
        "$tracer" --file "$data_dir/medium-none.parquet" --workload t3_full \
                  --arm p1-native --out "$results_dir/trace-medium-t3.jsonl"
        "$tracer" --file "$data_dir/medium-none.parquet" --workload t3_full \
                  --arm p2-sluice --out "$results_dir/trace-medium-t3-p2.jsonl"
        # Structural gate on the captured evidence: every line valid JSONL and
        # the two arms' request lists identical, checked with jq by a validator
        # that shares no code with the C++ trace parser.
        bash benchmarks/parquet/validate-trace.sh \
            "$results_dir/trace-medium-t3.jsonl" "$results_dir/trace-medium-t3-p2.jsonl"
        trace_args=(--trace)
    fi

    # Manifest last among the preparation steps: everything it records
    # (datasets, traces) now exists and has verified.
    write_manifest "${names[@]}"

    # Pass 1: warm the caches (file content + reader code paths). Discarded.
    run_pass warmup-pass
    # Pass 2: the sampled pass. Only this JSON feeds the summary.
    run_pass measure-pass

    echo "== summary"
    bash benchmarks/parquet/summarize.sh "$results_dir/measure-pass.json" \
        | tee "$results_dir/summary.txt"

    echo "== raw results: $results_dir/{warmup-pass,measure-pass}.json"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

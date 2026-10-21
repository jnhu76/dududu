#!/usr/bin/env bash
# Formal standalone Parquet benchmark protocol (R1).
#
#   bash benchmarks/parquet/run-bench.sh [small|medium|both]
#
# What it does, in order:
#   1. builds the fixture datasets, or verifies an existing one against the
#      identity record its generator wrote (existence alone proves nothing);
#      generation and verification are never timed;
#   2. captures the I/O request trace from diagnostic P1 and P2 runs
#      (untimed) and validates both structurally (validate-trace.sh);
#   3. writes the provenance manifest — only after the artifacts it names
#      exist and verify, so a fresh checkout can never record a manifest
#      without its dataset lines;
#   4. runs pass 1 as cache warm-up (results kept for reference only);
#   5. runs pass 2, the sampled pass: Google Benchmark with
#      --benchmark_repetitions=$REPS independent samples per benchmark,
#      arms registered interleaved per workload (P0,P1,P2 back-to-back);
#      every pass is admitted by validate-results.sh before it counts;
#   6. writes raw JSON to build/parquet-results/ and a human summary next to it.
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
fixture="$build_dir/experiments/parquet/parquet_fixture"
tracer="$build_dir/experiments/parquet/parquet_trace"
bench="$build_dir/experiments/parquet/parquet_bench"

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

dataset_line() { # <file> -> "DATASET <path> <sha256> <bytes>", fail if absent
    local f="$1"
    if [[ ! -f "$f" ]]; then
        echo "run-bench: manifest cannot record a missing artifact: $f" >&2
        return 1
    fi
    echo "DATASET $f $(sha256sum "$f" | awk '{print $1}') $(stat -c%s "$f")"
}

trace_line() { # <file> -> "TRACE <path> <sha256> <lines>"
    local f="$1"
    if [[ ! -f "$f" ]]; then
        echo "run-bench: manifest cannot record a missing artifact: $f" >&2
        return 1
    fi
    echo "TRACE $f $(sha256sum "$f" | awk '{print $1}') $(wc -l < "$f")"
}

# Provenance manifest (AGENTS rule 1 / matrix rule 4): every result set
# carries both SHAs, the SDK identity, the sampling parameters, the host and
# the digests of every artifact the numbers depend on. Called only after the
# datasets exist and verify; a selected dataset that cannot be recorded is a
# hard failure, never a silently incomplete manifest.
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
    mkdir -p "$results_dir"
    local dududu_sha sluice_sha
    dududu_sha=$(git rev-parse HEAD)
    sluice_sha=$(git -C third_party/sluice rev-parse HEAD)
    {
        echo "DUDUDU_SHA=$dududu_sha"
        echo "SLUICE_SHA=$sluice_sha"
        echo "SLUICE_PROFILE=noliburing"
        echo "SDK_PREFIX=build/sluice-sdk/noliburing"
        echo "ARROW_VERSION=$(pkg-config --modversion arrow 2>/dev/null || echo unknown)"
        echo "PARQUET_VERSION=$(pkg-config --modversion parquet 2>/dev/null || echo unknown)"
        echo "REPS=$REPS"
        echo "WARMUP_SECONDS=$WARMUP_SECONDS"
        echo "KERNEL=$(uname -r)"
        echo "DATE_UTC=$(date -u +%FT%TZ)"
        echo "COMPILER=$(g++ -dumpversion)"
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
}

main() {
    local selected="${1:-both}"
    [[ "$selected" == "small" || "$selected" == "medium" || "$selected" == "both" ]] || {
        echo "usage: run-bench.sh [small|medium|both]" >&2
        exit 2
    }
    mkdir -p "$data_dir" "$results_dir"

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

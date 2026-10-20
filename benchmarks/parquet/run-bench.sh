#!/usr/bin/env bash
# Formal standalone Parquet benchmark protocol (R1).
#
#   bash benchmarks/parquet/run-bench.sh [small|medium|both]
#
# What it does, in order:
#   1. builds the fixture datasets if absent (generation is never timed);
#   2. captures the I/O request trace from a diagnostic P1 run (untimed);
#   3. runs pass 1 as cache warm-up (results kept for reference only);
#   4. runs pass 2, the sampled pass: Google Benchmark with
#      --benchmark_repetitions=$REPS independent samples per benchmark,
#      arms registered interleaved per workload (P0,P1,P2 back-to-back);
#   5. writes raw JSON to build/parquet-results/ and a human summary next to it.
#
# Cache protocol: warm OS page cache only. Nothing here drops caches; the
# first pass exists so the second pass never pays a cold-cache tax.
set -euo pipefail

REPS="${DUDUDU_BENCH_REPS:-10}"
WARMUP_SECONDS="${DUDUDU_BENCH_WARMUP_S:-2}"

repo=$(git rev-parse --show-toplevel)
cd "$repo"
build_dir=build/cmake-parquet
data_dir=build/parquet-data
results_dir=build/parquet-results
fixture="$build_dir/experiments/parquet/parquet_fixture"
tracer="$build_dir/experiments/parquet/parquet_trace"
bench="$build_dir/experiments/parquet/parquet_bench"

mkdir -p "$data_dir" "$results_dir"

# Provenance manifest (AGENTS rule 1 / matrix rule 4): every result set
# carries both SHAs, the SDK identity, the sampling parameters and the host.
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
    for f in "$data_dir"/small-none.parquet "$data_dir"/medium-none.parquet; do
        [[ -f "$f" ]] && echo "DATASET $f $(sha256sum "$f" | awk '{print $1}') $(stat -c%s "$f")"
    done
} > "$results_dir/run-manifest.txt"

datasets="${1:-both}"
[[ "$datasets" == "small" || "$datasets" == "medium" || "$datasets" == "both" ]] || {
    echo "usage: run-bench.sh [small|medium|both]" >&2
    exit 2
}

gen() { # name
    local name="$1"
    if [[ ! -f "$data_dir/$name-none.parquet" ]]; then
        echo "== generating $name fixture (not timed)"
        "$fixture" --out "$data_dir" --dataset "$name"
    fi
}

run_pass() { # pass-name
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
    bash benchmarks/parquet/validate-results.sh "$json" "$datasets" "$REPS" "${trace_args[@]}"
}

[[ "$datasets" == "small" || "$datasets" == "both" ]] && gen small
[[ "$datasets" == "medium" || "$datasets" == "both" ]] && gen medium

if [[ "$datasets" == "medium" || "$datasets" == "both" ]]; then
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
fi

# Pass 1: warm the caches (file content + reader code paths). Discarded.
run_pass warmup-pass
# Pass 2: the sampled pass. Only this JSON feeds the summary.
run_pass measure-pass

echo "== summary"
bash benchmarks/parquet/summarize.sh "$results_dir/measure-pass.json" \
    | tee "$results_dir/summary.txt"

echo "== raw results: $results_dir/{warmup-pass,measure-pass}.json"

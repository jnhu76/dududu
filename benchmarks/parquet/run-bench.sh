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

run_pass() { # pass-name datasets
    local pass="$1"
    local small_args=() medium_args=()
    if [[ "$2" == "small" || "$2" == "both" ]]; then small_args=(--small="$data_dir/small-none.parquet"); fi
    if [[ "$2" == "medium" || "$2" == "both" ]]; then medium_args=(--medium="$data_dir/medium-none.parquet"); fi
    local json="$results_dir/$pass.json"
    echo "== $pass -> $json"
    "$bench" "${small_args[@]}" "${medium_args[@]}" \
        --trace="$results_dir/trace-medium-t3.jsonl" \
        --benchmark_repetitions="$REPS" \
        --benchmark_min_warmup_time="$WARMUP_SECONDS" \
        --benchmark_format=json \
        --benchmark_out="$json" >/dev/null
}

[[ "$datasets" == "small" || "$datasets" == "both" ]] && gen small
[[ "$datasets" == "medium" || "$datasets" == "both" ]] && gen medium

if [[ "$datasets" == "medium" || "$datasets" == "both" ]]; then
    echo "== capturing I/O trace (diagnostic, untimed)"
    "$tracer" --file "$data_dir/medium-none.parquet" --workload t3_full \
              --arm p1-native --out "$results_dir/trace-medium-t3.jsonl"
    "$tracer" --file "$data_dir/medium-none.parquet" --workload t3_full \
              --arm p2-sluice --out "$results_dir/trace-medium-t3-p2.jsonl"
fi

# Pass 1: warm the caches (file content + reader code paths). Discarded.
run_pass warmup-pass "$datasets"
# Pass 2: the sampled pass. Only this JSON feeds the summary.
run_pass measure-pass "$datasets"

echo "== summary"
bash benchmarks/parquet/summarize.sh "$results_dir/measure-pass.json" \
    | tee "$results_dir/summary.txt"

echo "== raw results: $results_dir/{warmup-pass,measure-pass}.json"

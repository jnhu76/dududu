#!/usr/bin/env bash
# Fail-closed admission validation for a sampled parquet benchmark pass.
#
#   bash benchmarks/parquet/validate-results.sh <benchmark.json> <small|medium|both> \
#           <reps> [--trace]
#
# A summary over a partial run must never look green. Before any numbers are
# accepted, this gate checks the raw Google Benchmark JSON against the exact
# roster the protocol requires:
#   * every expected benchmark (workload x arm x dataset, the 4-thread full
#     scan when medium ran, both replays when a trace was captured) is
#     present, and NO unexpected iteration entries exist;
#   * the FULL entry multiset closes over that roster: every (name, run_type,
#     aggregate_name) triple must belong to it, so a ghost aggregate (which
#     summarize.sh would enumerate alongside the admitted ones), a duplicate
#     entry or a mislabeled aggregate_name is an admission failure;
#   * each has exactly <reps> iteration entries whose repetition_index
#     covers 0..reps-1, with positive real_time and non-negative cpu_time;
#   * each has exactly one mean/median/stddev/cv aggregate, with positive
#     mean/median times and non-negative stddev/cv (an all-equal sample set
#     is zero-variance, not broken);
#   * no entry anywhere reported error_occurred (a SkipWithError or a
#     benchmark-filtered-out run is an admission failure, not a gap).
#
# Local evidence gate only (AGENTS: CI stays policy-only). Exit 0 = admitted.
set -euo pipefail

fail() {
    echo "validate-results: FAIL: $*" >&2
    exit 1
}

usage='usage: validate-results.sh <benchmark.json> <small|medium|both> <reps> [--trace]'
[[ $# -eq 3 || $# -eq 4 ]] || fail "$usage"
json="$1"
mode="$2"
reps="$3"
with_trace=0
[[ $# -eq 4 && "$4" == "--trace" ]] && with_trace=1
[[ "$mode" == "small" || "$mode" == "medium" || "$mode" == "both" ]] || fail "$usage"
[[ "$reps" =~ ^[0-9]+$ && "$reps" -ge 1 ]] || fail "reps must be a positive integer"
[[ -f "$json" ]] || fail "no such file: $json"

datasets=()
[[ "$mode" == "small" || "$mode" == "both" ]] && datasets+=(small)
[[ "$mode" == "medium" || "$mode" == "both" ]] && datasets+=(medium)

roster=()
for wl in T1_meta T2_projection T3_fullscan; do
    for ds in "${datasets[@]}"; do
        for arm in p0_arrow p1_native p2_sluice; do
            roster+=("$wl/$arm/$ds")
        done
    done
done
if [[ " ${datasets[*]} " == *" medium "* ]]; then
    for arm in p0_arrow p1_native p2_sluice; do
        roster+=("T3_fullscan_t4/$arm/medium/threads:4")
    done
fi
if [[ "$with_trace" -eq 1 ]]; then
    roster+=("Replay/native/medium" "Replay/sluice/medium")
fi
roster_json=$(printf '%s\n' "${roster[@]}" | jq -R . | jq -s .)

# 1. Nothing anywhere may carry an error (SkipWithError lands here).
errors=$(jq -r '[.benchmarks[]? | select(.error_occurred == true) | .name] | unique | join(", ")' \
    "$json" 2>/dev/null) || fail "$json: not parseable JSON"
[[ -z "$errors" ]] || fail "$json: error_occurred on: $errors"

# 2. The set of iteration entries is exactly the required roster: a missing
#    P2 arm or an unexpected extra benchmark are both admission failures.
jq -e --argjson roster "$roster_json" \
    '[.benchmarks[] | select(.run_type == "iteration") | .name] | unique == ($roster | sort)' \
    "$json" >/dev/null \
    || fail "$json: iteration entries do not match the required roster for mode=$mode trace=$with_trace"

# 3. Closure: the whole entry multiset must be exactly the roster expanded.
#    A ghost aggregate ("Ghost/extra_mean") passes every per-name check —
#    yet summarize.sh enumerates every aggregate it finds, so anything
#    outside the roster (extra aggregate, duplicate entry, aggregate_name
#    that does not match the name suffix) is an admission failure.
expected_sigs=$(for b in "${roster[@]}"; do
                    for ((i = 0; i < reps; i++)); do
                        printf '%s\titeration\t\n' "$b"
                    done
                    for s in mean median stddev cv; do
                        printf '%s_%s\taggregate\t%s\n' "$b" "$s" "$s"
                    done
                done | sort)
actual_sigs=$(jq -r '.benchmarks[]
                     | [(.name // ""), (.run_type // ""), (.aggregate_name // "")] | @tsv' \
                    "$json" | sort) || fail "$json: not parseable JSON"
delta=$(diff <(printf '%s\n' "$expected_sigs") <(printf '%s\n' "$actual_sigs") \
             | head -20) || true
if [[ -n "$delta" ]]; then
    printf '%s\n' "  roster closure delta ('<' expected, '>' present):" "$delta" >&2
    fail "$json: benchmark entries do not close over the required roster for mode=$mode trace=$with_trace"
fi

# 4. Per benchmark: exactly <reps> clean samples with dense repetition
#    indices and positive times, plus exactly one of each aggregate.
per_bench='
. as $root
| ($roster | map(
      . as $b
      | [$root.benchmarks[]
         | select(.run_type == "iteration" and .name == $b)] as $runs
      | ($runs | length == $reps)
        and ([$runs[] | .repetition_index] | sort == [range(0; $reps)])
        and ($runs | all((.real_time | type == "number" and . > 0)
                         and (.cpu_time | type == "number" and . >= 0)))
        and (["mean", "median", "stddev", "cv"] | map(
              . as $s
              | [$root.benchmarks[]
                 | select(.run_type == "aggregate" and .name == ($b + "_" + $s))] as $ag
              | ($ag | length == 1)
                and ($ag[0].real_time | type == "number" and . > 0)) | all)
    ) | all)'
jq -e --argjson roster "$roster_json" --argjson reps "$reps" "$per_bench" "$json" >/dev/null || {
    # Diagnostics: name the first offenders instead of a bare boolean.
    for b in "${roster[@]}"; do
        count=$(jq -r --arg b "$b" \
            '[.benchmarks[] | select(.run_type == "iteration" and .name == $b)] | length' "$json")
        if [[ "$count" != "$reps" ]]; then
            echo "  $b: $count/$reps iteration entries" >&2
            continue
        fi
        bad=$(jq -r --arg b "$b" \
            '[.benchmarks[]
              | select(.run_type == "iteration" and .name == $b)
              | select((.real_time | type != "number" or . <= 0) or (.cpu_time | type != "number" or . < 0))] | length' \
            "$json")
        [[ "$bad" == "0" ]] || echo "  $b: $bad iteration entries with invalid times" >&2
        for s in mean median stddev cv; do
            ag=$(jq -r --arg b "$b" --arg s "${b}_${s}" \
                '[.benchmarks[]
                  | select(.run_type == "aggregate" and .name == $s)
                  | select(.real_time | type != "number" or . <= 0)] | length' "$json")
            [[ "$ag" == "0" ]] || echo "  ${b}_${s}: missing or invalid aggregate" >&2
        done
    done
    fail "$json: roster admission failed (details above)"
}

echo "validate-results: PASS ($json: ${#roster[@]} benchmarks x $reps samples, mode=$mode trace=$with_trace)"

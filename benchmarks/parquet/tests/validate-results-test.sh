#!/usr/bin/env bash
# Negative-first self-test for benchmarks/parquet/validate-results.sh.
#
# The admission gate must be seen rejecting every partial or corrupted shape
# it exists to stop: missing arm, missing aggregate, missing repetition,
# SkipWithError, zero times, extra benchmarks, truncated JSON, wrong mode.
# The valid fixture is synthesized with jq (no dependency on a prior run).
# One of the rejections below (aggregate truthiness) caught a real bug in
# the validator's own jq on first run; that is the point of the suite.
set -u

here=$(cd "$(dirname "$0")" && pwd)
validator="$here/../validate-results.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fails=0
cases=0
fail_now() {
    echo "FAIL: $*" >&2
    fails=$((fails + 1))
}

expect_pass() { # <label> <args...>
    cases=$((cases + 1))
    if ! bash "$validator" "${@:2}" >/dev/null 2>&1; then
        fail_now "expected PASS, got reject: $1"
    fi
}

expect_reject() { # <label> <args...>
    cases=$((cases + 1))
    if bash "$validator" "${@:2}" >/dev/null 2>&1; then
        fail_now "expected REJECT, got pass: $1"
    fi
}

REPS=3
gen_valid() { # <reps> -> synthetic admitted JSON on stdout
    jq -n --argjson reps "$1" '
      ["T1_meta","T2_projection","T3_fullscan"] as $wls
      | ["small","medium"] as $ds
      | ["p0_arrow","p1_native","p2_sluice"] as $arms
      | ([$wls[] as $w | $ds[] as $d | $arms[] as $a | "\($w)/\($a)/\($d)"]
         + [$arms[] as $a | "T3_fullscan_t4/\($a)/medium/threads:4"]
         + ["Replay/native/medium", "Replay/sluice/medium"]) as $roster
      | {context: {}, benchmarks:
         [$roster[] as $b
          | (range(0; $reps) as $i
             | {name: $b, run_type: "iteration", repetition_index: $i,
                real_time: 100 + $i, cpu_time: 90 + $i}),
            (["mean","median","stddev","cv"][] as $s
             | {name: ($b + "_" + $s), run_type: "aggregate",
                aggregate_name: $s, real_time: 100})]}
    '
}

gen_valid "$REPS" > "$tmp/valid.json"

# --- admitted shape ----------------------------------------------------------
expect_pass "synthetic full roster" "$tmp/valid.json" both "$REPS" --trace

# --- partial admissions must not pass ----------------------------------------
jq 'del(.benchmarks[] | select(.name == "T3_fullscan/p2_sluice/medium_mean"))' \
    "$tmp/valid.json" > "$tmp/drop-agg.json"
expect_reject "missing _mean aggregate of one P2 arm" "$tmp/drop-agg.json" both "$REPS" --trace

jq 'del(.benchmarks[] | select(.name == "T3_fullscan/p2_sluice/medium"
                               and .repetition_index == 1))' \
    "$tmp/valid.json" > "$tmp/drop-rep.json"
expect_reject "one repetition short" "$tmp/drop-rep.json" both "$REPS" --trace

jq 'del(.benchmarks[] | select(.name == "Replay/sluice/medium"))' \
    "$tmp/valid.json" > "$tmp/drop-bench.json"
expect_reject "whole benchmark missing" "$tmp/drop-bench.json" both "$REPS" --trace

jq '(.benchmarks[] | select(.name == "T1_meta/p1_native/small"
                            and .repetition_index == 2) | .error_occurred) = true' \
    "$tmp/valid.json" > "$tmp/err.json"
expect_reject "SkipWithError sample" "$tmp/err.json" both "$REPS" --trace

jq '(.benchmarks[] | select(.name == "T2_projection/p0_arrow/medium_mean")
     | .real_time) = 0' "$tmp/valid.json" > "$tmp/zero-agg.json"
expect_reject "zero-time aggregate" "$tmp/zero-agg.json" both "$REPS" --trace

# An all-equal sample set is a legal zero-variance result: its stddev and cv
# aggregates are exactly 0. Only mean/median must stay positive.
jq '(.benchmarks[]
     | select(.name == "T1_meta/p1_native/small" and .run_type == "iteration")
     | .real_time) = 100
    | (.benchmarks[]
       | select(.name == "T1_meta/p1_native/small_stddev"
                or .name == "T1_meta/p1_native/small_cv")
       | .real_time) = 0' "$tmp/valid.json" > "$tmp/zero-var.json"
expect_pass "zero-variance sample set is legal" "$tmp/zero-var.json" both "$REPS" --trace

jq '(.benchmarks[] | select(.name == "T2_projection/p2_sluice/small"
                            and .repetition_index == 0) | .real_time) = -1' \
    "$tmp/valid.json" > "$tmp/neg.json"
expect_reject "negative sample time" "$tmp/neg.json" both "$REPS" --trace

jq '.benchmarks += [{name: "T9_ghost/p1_native/small", run_type: "iteration",
                     repetition_index: 0, real_time: 1, cpu_time: 1}]' \
    "$tmp/valid.json" > "$tmp/extra.json"
expect_reject "unexpected extra benchmark" "$tmp/extra.json" both "$REPS" --trace

jq '.benchmarks += [{name: "Ghost/extra_mean", run_type: "aggregate",
                     aggregate_name: "mean", real_time: 100}]' \
    "$tmp/valid.json" > "$tmp/ghost-agg.json"
expect_reject "aggregate outside the roster" "$tmp/ghost-agg.json" both "$REPS" --trace

jq '.benchmarks += [.benchmarks[] | select(.name == "T1_meta/p0_arrow/small_mean")]' \
    "$tmp/valid.json" > "$tmp/dup-agg.json"
expect_reject "duplicated aggregate entry" "$tmp/dup-agg.json" both "$REPS" --trace

jq '(.benchmarks[] | select(.name == "T2_projection/p1_native/medium_mean")
     | .aggregate_name) = "median"' "$tmp/valid.json" > "$tmp/map-agg.json"
expect_reject "aggregate_name mislabeled" "$tmp/map-agg.json" both "$REPS" --trace

head -c 400 "$tmp/valid.json" > "$tmp/trunc.json"
expect_reject "truncated JSON" "$tmp/trunc.json" both "$REPS" --trace

# --- protocol-argument mismatches ---------------------------------------------
expect_reject "reps argument above what ran" "$tmp/valid.json" both $((REPS + 1)) --trace
expect_reject "mode small against a both roster" "$tmp/valid.json" small "$REPS"
jq 'del(.benchmarks[] | select(.name | startswith("Replay/")))' \
    "$tmp/valid.json" > "$tmp/no-trace.json"
expect_pass "no-trace roster without the flag" "$tmp/no-trace.json" both "$REPS"
expect_reject "trace flag against a no-trace roster" "$tmp/no-trace.json" both "$REPS" --trace
expect_reject "missing file" "$tmp/does-not-exist.json" both "$REPS"
expect_reject "bad mode" "$tmp/valid.json" galactic "$REPS"
expect_reject "bad reps" "$tmp/valid.json" both zero

if [[ $fails -ne 0 ]]; then
    echo "validate-results-test: $fails failure(s) over $cases cases" >&2
    exit 1
fi
echo "validate-results-test: PASS ($cases cases, negative-first)"

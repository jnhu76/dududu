#!/usr/bin/env bash
# Summarize a Google Benchmark JSON run into the R1 attribution table.
#
#   bash benchmarks/parquet/summarize.sh <benchmark.json>
#
# Google Benchmark JSON layout used here:
#   * per-run entries:  name "<bench>", aggregate_name null, flat counters
#   * aggregates:       name "<bench>_mean" / "_median" / "_stddev" / "_cv"
# Reports, per workload x dataset, from the aggregate entries:
#   Wrapper Tax       = T(P1) / T(P0) - 1
#   Sluice Effect     = T(P2) / T(P1) - 1
#   End-to-End Change = T(P2) / T(P0) - 1
# Ratios are never summed; each line stands alone.
set -euo pipefail

json="${1:?usage: summarize.sh <benchmark.json>}"

first_of() { # jq filter body
    jq -r "$1" "$json"
}

printf "%-36s %12s %12s %8s %8s %14s %6s\n" \
    BENCH MEAN_ns MEDIAN_ns CV% IO_REQ REQ_BYTES ERRS

for name in $(jq -r '.benchmarks[] | select(.aggregate_name == "mean") | .name' "$json"); do
    base="${name%_mean}"
    mean=$(jq -r --arg n "$name" '.benchmarks[] | select(.name == $n) | .real_time' "$json")
    med=$(jq -r --arg n "${base}_median" '.benchmarks[] | select(.name == $n) | .real_time' "$json")
    cv=$(jq -r --arg n "${base}_cv" '.benchmarks[] | select(.name == $n) | .real_time' "$json")
    read -r io req errs rows <<<"$(jq -r --arg n "$base" \
        '[.benchmarks[] | select(.name == $n and .aggregate_name == null)][0]
         | [(.io_calls // 0), (.requested_bytes // 0), (.read_errors // 0), (.rows // 0)] | @tsv' \
        "$json")"
    printf "%-36s %12.0f %12.0f %7.2f%% %8.0f %14.0f %6.0f\n" \
        "$base" "$mean" "$med" "$(awk -v c="$cv" 'BEGIN{print c*100}')" "$io" "$req" "$errs"
done

echo
echo "attribution (mean wall time; each ratio stands alone):"
for wl in T1_meta T2_projection T3_fullscan; do
    for ds in small medium; do
        t() {
            jq -r --arg n "$wl/$1/${ds}_mean" \
                '.benchmarks[] | select(.name == $n) | .real_time // empty' \
                "$json"
        }
        p0=$(t p0_arrow); p1=$(t p1_native); p2=$(t p2_sluice)
        if [[ -n "$p0" && -n "$p1" && -n "$p2" && "$p0" != "0" && "$p1" != "0" ]]; then
            awk -v wl="$wl/$ds" -v p0="$p0" -v p1="$p1" -v p2="$p2" \
                'BEGIN {
                    printf "%-24s wrapper_tax=%+7.2f%%  sluice_effect=%+7.2f%%  e2e=%+7.2f%%\n",
                        wl, (p1/p0-1)*100, (p2/p1-1)*100, (p2/p0-1)*100;
                }'
        fi
    done
done

echo
echo "replay (I/O-only; identical request trace both backends):"
tn=$(jq -r '.benchmarks[] | select(.name == "Replay/native/medium_mean") | .real_time // empty' "$json")
ts=$(jq -r '.benchmarks[] | select(.name == "Replay/sluice/medium_mean") | .real_time // empty' "$json")
if [[ -n "$tn" && -n "$ts" ]]; then
    awk -v tn="$tn" -v ts="$ts" 'BEGIN { printf "  native=%.1fms sluice=%.1fms sluice/native=%++.2f%%\n", tn/1e6, ts/1e6, (ts/tn-1)*100 }'
fi

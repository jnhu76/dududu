# DuckDB R0 measurement-lane completion receipts — E5 (2026-10-29)

Completes `prep-record.md`: the serial measurement lane ran after prep; this
file records what the lane established, at receipt granularity. Raw outputs
(run logs, JSON, strace traces) live in the Sluice research tree
(`research/direct-beyond-parity/closure/r5-native/`) and never enter dududu
git (rule 6). The full §8.5 report is `docs/DUCKDB_FIO_R0_PREREG.md`.

## Oracle re-verification [RUN]

Two fresh lane runs of `../oracle.sql` (lane-r1, lane-r2): all four CSV
SHA-256s identical across runs and equal to the prep-record hashes (q1
`54adfd20…`, q2 `6b7830dd…`, q3 `673ce9f4…`, q4 `26788f24…`). Byte/value
oracle: the official benchmark's upstream `result` oracle passed with zero
INCORRECT lines (`benchmark_runner.cpp:122` gate) across all **62**
benchmark-runner invocations in the lane (30 W1 + 30 W1b + 2 cold-timing).

## A/A noise pairs [RUN] — closes prep's NOT_RUN item

Three pre-declared workloads, serial exclusive lane, per-invocation oracle
gate; 73 pairs total, ≥15 on every workload:

| Workload | config | invocations / pairs | mean | CV | pair mean / max |
|---|---|---|---|---|---|
| W1 | official benchmark, default threads (20, all cores) | 30 / 29 | 20.813 ms | 7.39% | 8.71% / 23.87% |
| W1b | official benchmark, `taskset -c 2-9 --threads=4` (**of record**) | 30 / 29 | 35.887 ms | 4.46% | 4.90% / 13.86% |
| W2 | 4-query oracle suite, whole-process wall, `taskset -c 2-9` | 16 / 15 | 0.296 s | 1.67% | 1.49% / 4.08% |

Resolution limits: paired A/B at n=15 resolves ≈ ±3–5% on W1b, ≈ ±1% on W2;
no power analysis against a preregistered effect size. The unpinned W1
configuration is the recorded noise regime future A/Bs must avoid by pinning
cores and declaring thread counts.

## Cold-cache timing [RUN] — closes prep's drop_caches NOT_RUN item

Two W1b invocations after `sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'`
(measurement-permission sudo, disclosed in the lane's environment record):
first repeat +25–40% (8–14 ms) over warm steady state; third repeat back
inside the warm band. Warm-only limitation superseded by this grant; every use
logged.

## I/O exposure, cold vs warm [RUN] — closes prep's per-attribution item

Request stream byte-identical cold and warm: 492 `pread64` on
`lineitem.parquet`, 37,172,128 B, 0 short reads, in both runs. Per-column
attribution: `SUM(l_extendedprice)` 100 preads / 31,086,130 B;
`SUM(l_discount)` 198 / 3,123,007 B; `COUNT(*)` 2 / 79,621 B (metadata
floor). 344 calls (70%) are ≤4 KiB moving 0.13% of bytes. All reads unaligned
(offset/length mod 512 ≠ 0) — `O_DIRECT` cannot pass the stream as-is.
Seam symbolized with `strace -k`; matches `docs/duckdb-stable-io-map.md`
§1.1. Kernel-level perf hotspot: NOT_RUN_WITH_REASON
(`perf_event_paranoid=2`; relaxing a security setting was not authorized).

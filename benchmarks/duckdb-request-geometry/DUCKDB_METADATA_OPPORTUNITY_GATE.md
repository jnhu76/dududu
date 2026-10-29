# DuckDB Metadata Micro-Read — Opportunity Gate (R1, mission Phases 6.3/6.4)

Verdict of the Phase 6.4 opportunity gate, evaluated over the request
geometry in [DUCKDB_METADATA_REQUEST_GEOMETRY.md](DUCKDB_METADATA_REQUEST_GEOMETRY.md):

```text
METADATA_IO_OPPORTUNITY_VERDICT = NO_MATERIAL_OPPORTUNITY
```

The syscall reduction is real, reproducible and free of extra data bytes —
but its query-time value on this workload has a measured upper bound
(~0.22–0.3 ms/query serial, ≤ ~0.8% of the seam-query mean) that sits below
every wall-clock resolution this project has recorded, and two bounded
in-session probes could not resolve any difference. Per the gate rule, no
adapter is built and the formal A/B is not spent. This document records the
cost model, the mechanism screening, the correctness oracle, the bounded
probes and the five gate criteria. Recommendations for Sluice AC-1/2/3 and
the next-stage admission conditions are in
[SLUICE_AC_RECOMMENDATIONS.md](SLUICE_AC_RECOMMENDATIONS.md).

Evidence tagging: `[gate]` = the Phase 6.3/6.4 gate session (2026-10-29; raw
outputs under `/tmp/gate-probe/`, hashes in §10; session log `logs/gate.md`).
`[verify]` = independent re-checks run while preparing the research PR
(2026-10-29), listed in §10. `[geometry]` = the committed Phase 6.2 document.

Identities (re-verified `[verify]`):

| item | value |
|---|---|
| dududu base | merged main `12a8712eb5ff5f48e570b49b1e01ad5821837dca` (PR #7); branch `r1-request-geometry` @ `434416ebb1e5d707b815c1f563131e99422bb8e7` |
| DuckDB | submodule `069cc9f9b5be802405797faecc284961b07c70ef` = v1.5.6, unmodified; binary `build/duckdb-native/069cc9f9…/duckdb`, sha256 `2fa47786f0fe1c3fbedb13e17f73ae0bfdeecb263d8bbd792521c75a07edbaa2` |
| dataset | `build/duckdb-bench/duckdb_benchmark_data/lineitem.parquet`, 207,130,013 B, sha256 `b7583e65198aaa9522067fd849f9d08f2668df2e7608fef548ab386cab0ef911` (= `benchmarks/duckdb-r0/results/prep-record.md`) |
| seam query | `SELECT SUM(l_extendedprice*(1-l_discount)*(1+l_tax)) FROM read_parquet('duckdb_benchmark_data/lineitem.parquet')`; benchmark result oracle `226829357828.867781` |
| host | E5-2666 v3; probes pinned `taskset -c 2-9` (W1b regime of record) |

## 1. Input to the gate

From `[geometry]`: the default stream is 492 preads / 37,172,128 B per seam
query, 344 of them ≤ 4 KiB metadata-structure fetches (48,674 B, 0.131% of
bytes). Exactly one legal coalescing window exists — **W1**, the contiguous
projected three-chunk span of each row group, all addresses known at open
time (T0) from the footer DuckDB already parses. W1 is not a proposal: it is
the existing v1.5.6 mechanism `prefetch_all_parquet_files`, gated off for
on-disk files by `ShouldAndCanPrefetch`
(`parquet_reader.cpp:48-56`, re-checked `[verify]`). The gate evaluates
whether turning that legal window into any Sluice-side or adapter-side
mechanism has a material, measurable payoff. It does not.

## 2. Syscall delta, re-measured at gate time `[gate]`

`strace -f -y -e trace=pread64` on the seam query, `threads=4`, `taskset 2-9`
(raw: `st-a-4thr.txt`, `st-b-4thr.txt`):

| arm | preads on lineitem.parquet | bytes returned | ≤ 4 KiB |
|---|---|---|---|
| A — default (`SET threads=4;`) | 492 | 37,172,128 | 344 (48,674 B) |
| B — `+ SET prefetch_all_parquet_files=true;` | 50 | 37,315,569 | 0 |

Δ = −442 preads (−89.8%), −344 micro-fetches → 0, +143,441 B returned
(+0.39%). Matches the `[geometry]` single-threaded measurement (492 → 50)
exactly. `[verify]` recount: path-carrying `pread64` lines = 492 / 50 (each
pread appears exactly once with its fd annotation; unfinished/resumed splits
pair 1:1). Both arms produce the oracle aggregate (§4).

## 3. Cost model

**Saved-syscall value (serial upper bound).** `replay.c` (gcc -O2) replays
the recorded `(offset, len)` sequences against the dataset directly, warm
page cache, 300 passes, `taskset 2-9`; the driver treats the first CSV line
as a header, so it replays 491/49 of the 492/50 requests.

- `[gate]` run: req-a (default sequence) median 3854.0 µs/pass (min 3805.1);
  req-b (merged sequence) median 3632.2 µs/pass (min 3589.0); **Δ = 221.8 µs
  per query ≈ 0.50 µs per avoided pread entry**.
- `[verify]` delivery re-run, same binary and inputs: median 3902.8 µs
  (min 3872.6) vs 3609.2 µs (min 3579.8); **Δ = 293.6 µs ≈ 0.66 µs/entry** —
  same direction, same band.

Both arms copy ~37 MB, so the delta isolates syscall entry. The serial value
of the 442 saved entries is **≈ 0.22–0.3 ms/query**, i.e. **≤ ~0.8% of the
W1b seam-query mean (35.887 ms, `lane-record.md`)**. At 4 scan threads the
saved entries overlap with scan work, so wall-clock benefit is bounded by
this figure and not guaranteed to reach it.

**Planner CPU `[gate]`.** ≈ 0: chunk offsets and sizes come from the footer
metadata the reader already parses (`RegisterPrefetch` /
`FinalizeRegistration`, `parquet_reader.cpp:1447-1515`), and the span merge
is the reader's own `ReadAheadBuffer` with `ALLOW_GAP = 16 KiB`
(`thrift_tools.hpp:39-101`; re-checked `[verify]`). No Sluice-side planner
exists and none is proposed.

**Extra bytes.** +143,441 B returned (+0.39%): the 49 data spans are exact
(37,053,425 B, byte-for-byte match with the projected-chunk table
`[geometry]`); the entire excess is the one-time 262,144 B footer prefetch
window (+182,523 B over the default 79,613 B footer read).

**Buffers.** Transient per-thread span buffers (mean ≈ 756 KB) plus the
256 KiB footer window; released by the reader's `ClearPrefetch`.

**Copies.** Body bytes unchanged; one-time footer-window excess as above.

**Responsibility.** The whole mechanism is DuckDB-internal. Zero Sluice
public API surface, zero new Sluice runtime state.

## 4. Correctness oracle `[gate]`, hashes re-checked `[verify]`

- Aggregate seam query: `226829357828.867781` in **both** arms across every
  recorded invocation (probe1: 64, probe2: 72, plus both §2 strace runs) —
  equal to the official benchmark's recorded `result` value.
- GROUP BY oracle (TPC-H q1 shape: returnflag/linestatus sums + `COUNT(*)`):
  arm A output `out-A.txt` and arm B output `out-B.txt` are byte-identical,
  sha256 `39a881d18cd795742d28090ba96d8bb9b22928ff24b8f603b0e0e4fc0d0353c3`
  for both (recomputed `[verify]`); 4 groups with canonical sf=1 values;
  `COUNT(*)` = 6,001,215 (= `prep-record.md` q1 row count).
- 0 short reads in both modes (this session, and all 1,282 preads across the
  four R0 traces per `[geometry]` §5); the replay driver aborts on any short
  read and did not.

Correctness admission therefore precedes the performance reads (dududu
rule 2): both arms are admissible; neither arm shows a semantic difference.

## 5. Bounded wall-clock probes `[gate]`; statistics recomputed from the raw JSON `[verify]`

Budget was pre-stated before running: two probes only, no formal A/B — the
formal arm was conditional on the gate passing, and it did not. Config per
invocation: fresh process, `taskset -c 2-9`, `SET threads=4;` (B adds
`SET prefetch_all_parquet_files=true;`), 8× seam query, whole-process wall
via `perf_counter`, all 8 output values asserted identical.

**probe1** — 70 invocations + 6 warmups (warmup 3+3; AA1 n=16; AB 16×(A,B);
AA2 n=16; `probe-raw.json`):

- A: n=48, mean 291.46 ms/invocation (36.43 ms/query), CV 3.86%.
  B: n=16, mean 301.26 ms (37.66 ms/query), CV 4.99%.
- A/A within-block consecutive-pair |rel diff|: mean 3.78%, max 11.04%
  (n=45) — consistent with R0's recorded W1b pair noise (mean 4.90%,
  `lane-record.md`).
- Drift confound: identical-arm block means AA1 290.31 / AB-armA 296.74 /
  AA2 287.33 ms (±3.3% swing); `/proc/loadavg` 0.13 → 1.45 across the run
  (transient host activity). The unpaired A-vs-B comparison is confounded.
- AB paired: mean(A−B) = −4.517 ms = −1.55% of A mean (recomputed from the
  raw JSON; the gate session log wrote −1.52%), A-faster in 7/16 pairs;
  uncorrected Welch t = −2.32 — not interpretable as an effect given the
  drift confound above.

**probe2** — 72 invocations: 9× drift-cancelling ABBA quads interleaved with
9× AAAA null quads; estimator `((a₁+a₄)−(b₁+b₂))/2` per quad
(`probe2-raw.json`):

- ABBA estimator: mean −6.96 ms, sd 14.02 ms, 95% CI **[−17.53, +3.61] ms**
  (t₈) — covers 0; quad scatter [−31.8, +13.6] ms.
- Null (A−A) estimator: mean −2.42 ms, sd 11.33 ms — indistinguishable from
  the ABBA estimator (t ≈ −0.76).

**Resolution verdict.** The serial upper bound (0.22–0.3 ms/query ≈ ≤ 2.4 ms
per 8-query invocation, wall-clock ≤ that) is ~60× smaller than the estimator
noise floor, below R0's recorded W1b paired resolution (±3–5%) and below W2
(±1%). Across 142 recorded invocations no wall-clock difference was
resolvable, and the expected effect size predicts none would be.

## 6. Mechanism screening (mission §6.3)

| mechanism | verdict on this workload |
|---|---|
| **M0** Native baseline | default v1.5.6 = the 492-pread stream; re-measured §2. |
| **M1** Sluice Sync Direct | inapplicable. All R0 reads unaligned (`lane-record.md`); O_DIRECT showed no benefit on this host; the 442 saved requests are warm-cache metadata fetches costing ~0.5–0.7 µs entry each, which O_DIRECT would raise, not lower. Sync Direct replays the same request shape: −0 syscalls. |
| **M2** Legal contiguous vectored read | no legal decomposition. Default-stream adjacent pairs overlap (15/29 per-fd transitions) or gap; W1 spans are consumed by one reader state machine, not discrete caller buffers; fusing non-contiguous offsets into `preadv` is illegal. Inapplicable (`[geometry]` §6). |
| **M3** Explicit metadata read planning | applicable — and already shipped upstream as `prefetch_all_parquet_files` (the W1 mechanism). Executed cost model: §3. The only mechanism with any substrate in this trace. |
| **M4** Gather/Dedup (AC-2 as comparator) | no product authorization (mission §0; default dedup rejected by the E5 AC-2 closure); repeated extents = 0 across all 1,282 preads `[geometry]` — no substrate even as a research comparator. Inapplicable. |
| **M5** True Async | this round produces a Host Protocol Research Packet only; R0 verdict `REQUIRES_HOST_CHANGE`. The T1 dependency (body address knowable only after header parse, `[geometry]` §5) forbids legal intra-row-group overlap; cross-row-group parallelism is already provided by scan threads; the ceiling is the same §3 entry-cost figure. No v1.5.6 implementation is permitted, and no material benefit above noise exists in any case. |

## 7. Opportunity gate — five criteria (mission §6.4)

| # | criterion | result |
|---|---|---|
| 1 | legal coalescible set exists in the real trace | **PASS** — W1: 49 contiguous projected spans, T0-knowable, executed as the 50-pread run (§2). |
| 2 | saved syscall/repeat cost quantifiable | **PASS** — −442 preads, −344 micro-fetches, measured twice (§2, `[geometry]`). |
| 3 | merge/planner cost does not offset benefit | **PASS** — planner ≈ 0 CPU, +0.39% one-time bytes, no offset observed (§3). |
| 4 | request content & query result identical | **PASS** — oracle-equal aggregate, byte-identical GROUP BY, exact-count reads (§4). |
| 5 | estimated benefit plausibly exceeds R0's recorded measurement resolution | **FAIL** — 0.22–0.3 ms serial upper bound (≤ ~0.8% of W1b mean) vs ±3–5% (W1b) / ±1% (W2); two probes unresolvable (§5). |

## 8. Verdict and claims discipline

`NO_MATERIAL_OPPORTUNITY` (mission §6.4: benefit upper bound clearly below
statistical detection → no forced adaptation).

- **Claimed (real):** the W1 syscall reduction is real and reproducible
  (−442 preads, −344 micro-fetches per seam query), costs +0.39% one-time
  bytes, is correctness-preserving (§4), and is already available upstream
  behind `SET prefetch_all_parquet_files=true` with zero Sluice code.
- **Not claimed:** any query-time improvement on this workload; any Sluice
  adapter or API; any DuckDB host change. The formal A/A + paired A/B was
  **not run**, by the gate's own rule — the bounded probes above are gate
  inputs, not experiment results.

### Research results record

```json
{
  "study": "duckdb-metadata-micro-read-r1",
  "verdict": "NO_MATERIAL_OPPORTUNITY",
  "syscall_delta_per_seam_query": {"default_preads": 492, "merged_preads": 50, "micro_reads_4k": {"before": 344, "after": 0}},
  "cost_model": {"saved_syscall_value_serial_ms_query_upper_bound": 0.3, "planner_cpu": "~0", "extra_bytes_ratio": "+0.39% one-time"},
  "probe_resolution": {"w1b_paired": "±3-5%", "w2": "±1%", "bounded_probes": "ABBA CI [-17.53,+3.61] ms covers 0"},
  "ab_experiment": {
    "ran": false,
    "result": "",
    "reason": "机会门判定无需实验（NO_MATERIAL_OPPORTUNITY）"
  }
}
```

## 9. Re-open conditions

The gate re-opens only for a workload whose seam is **syscall-entry- or
latency-dominated**: many small files per query, cold scans on high-latency
storage, or per-file metadata storms. Any re-open must re-run request
geometry on the new trace first (total-attribution analyzer, this module),
and the predicted effect must clear the recorded resolutions (W1b ±3–5%,
W2 ±1%) before any adapter implementation or formal A/B. See
[SLUICE_AC_RECOMMENDATIONS.md](SLUICE_AC_RECOMMENDATIONS.md) §6–§7.

## 10. Provenance and reproduction

Raw gate outputs live in `/tmp/gate-probe/` (ephemeral) and never enter
dududu Git (rule 6); the numbers above are the record. Hashes recomputed at
PR time `[verify]`:

| file | sha256 | content |
|---|---|---|
| `st-a-4thr.txt` | `d422b5ac35e56788c546dbe57010419459ddf88c2ab1a4046e7b9d6b08c42765` | strace, arm A (default), threads=4 |
| `st-b-4thr.txt` | `8f2c955954235825544bcdd373d127a6ee0fb9be0af877828212e57bff514e7f` | strace, arm B (+prefetch), threads=4 |
| `req-a.csv` | `e1d523a0b76f4ce85f946aac44fed82f9a4dcfff4813c8dd5402f93c9103c827` | replay input, default sequence (492 requests) |
| `req-b.csv` | `ac73d0814ee51d3f88749c7abf9e3ac9c3081f7257304f12e2159992a19e5914` | replay input, merged sequence (50 requests) |
| `replay.c` | `7677f1fca2004f629a9abbd934de50e283fb7ed8931182a5603c1bb7677fe352` | replay driver (one-shot session tool, kept out of Git) |
| `probe.py` | `10143900170a822d68b274ec14103973b8e00bf593b4c853366cfd67bb25ad25` | probe1 driver |
| `probe2.py` | `61d065183bdb687d41b7b4a286f1ebe3a8d1dcff56b575fc92fd8cbf7041e489` | probe2 driver |
| `probe-raw.json` | `0230d93e05c22b8d3c843c2106f9b3ad1041583e85f23ab78f19174ca3ec2ba5` | probe1 raw walls (n=64) |
| `probe2-raw.json` | `ac4e837689bacd51888188a56e3dfe70baab51f4346662c8db5f34d4f55f4ca6` | probe2 raw quads (n=9) |
| `out-A.txt` / `out-B.txt` | `39a881d18cd795742d28090ba96d8bb9b22928ff24b8f603b0e0e4fc0d0353c3` (both) | GROUP BY oracle outputs, byte-identical |

Reproduce the decisive measurements:

```bash
# syscall delta (§2)
strace -f -y -e trace=pread64 -o st-a.txt taskset -c 2-9 <duckdb> -noheader -list \
  -c "SET threads=4; SELECT SUM(l_extendedprice*(1-l_discount)*(1+l_tax)) FROM read_parquet('duckdb_benchmark_data/lineitem.parquet');"
# arm B: prepend SET prefetch_all_parquet_files=true;

# serial replay value (§3): build replay.c, then per arm
taskset -c 2-9 ./replay req-a.csv 300   # default sequence (note: driver skips line 1 -> 491 requests)
taskset -c 2-9 ./replay req-b.csv 300   # merged sequence (49 of 50)

# wall-clock probes (§5): probe.py / probe2.py as committed hashes above
```

Session logs: `logs/gate.md` (gate session), `logs/geometry.md` (Phase 6.2).

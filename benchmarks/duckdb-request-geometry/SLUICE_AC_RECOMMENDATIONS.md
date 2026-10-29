# Sluice AC-1/2/3 recommendations from the metadata micro-read gate (R1, mission Phase 6.5)

What the DuckDB metadata micro-read study does — and does not — recommend for
the Sluice Direct API design candidates, and the admission conditions for any
next-stage product or Host API work from this research line.

Inputs: [DUCKDB_METADATA_REQUEST_GEOMETRY.md](DUCKDB_METADATA_REQUEST_GEOMETRY.md)
(Phase 6.2), [DUCKDB_METADATA_OPPORTUNITY_GATE.md](DUCKDB_METADATA_OPPORTUNITY_GATE.md)
(Phases 6.3/6.4, verdict `NO_MATERIAL_OPPORTUNITY`). This study neither uses
nor implements any AC public API; it evaluates the workload as evidence.

Sluice-side state re-verified on 2026-10-29 via `gh`: #605 (AC-1), #606
(AC-2), #607 (AC-3) all OPEN and **Awaiting Owner**; #578 OPEN; the E5 design
closures are archived on Sluice master via merged #610 at
`research/direct-beyond-parity/closure/r6-ac1/` (master `84e1b7d5`).

## 1. Summary

**This workload recommends adopting none of AC-1/2/3 and no host change.**
Its single structural opportunity — the contiguous per-row-group projected
span (W1) — is already served in-tree by DuckDB's
`prefetch_all_parquet_files` at zero Sluice cost, its query-time value on
this workload is below every recorded measurement resolution
(`NO_MATERIAL_OPPORTUNITY`), and the trace has no substrate for gather, dedup
or vectored fan-out. The AC candidates remain Owner-gated design decisions to
be judged on other workloads; nothing here advances or blocks them except as
a negative control for auto-merge policies (§3).

## 2. AC-1 — positional vectored read/write (#605): no driver from this workload

The one legal coalescing window (W1) is a contiguous file span consumed by a
single reader state machine into one growable buffer
(`[geometry]` §5–§6). A k-buffer vectored call (`read_at_vectored`) would
have k = 1 on every request of this stream — a degenerate form of `read_at`
with no fan-out to amortize. The requests that are *not* part of W1 (footer
probes, 256-B header windows, cache-interleave pieces) are non-contiguous,
overlapping or T1-parse-dependent, so no legal vectored shape covers them.

**Recommendation:** this study adds no adoption driver for AC-1. Keep the
candidate Awaiting Owner and judge it on workloads that actually fan one
contiguous extent across discrete caller buffers.

## 3. AC-2 — gathered positioned read (#606): no substrate; negative control for auto-merge

- **Dedup has nothing to do:** zero repeated `(offset, len)` extents across
  all 1,282 preads of the four R0 traces (`[geometry]` §4) — no dedup
  substrate exists even as a research comparator (gate M4, inapplicable).
- **No legal gather exists:** the default stream's adjacent requests overlap
  (15/29 per-fd transitions are self-overlaps) or are separated by a T1
  parse dependency (body address knowable only after the 256-B header
  window is fetched and parsed, `[geometry]` §5); row-group switches gap
  ~2.4 MB. Synthesizing one request set from these would be exactly the
  illegal M2 shape (fusing non-contiguous offsets).
- **This trace is the cautionary case for a default-on merge policy:** 344
  calls ≤ 4 KiB (70% of calls) is precisely the surface where "batch the
  micro-reads" looks tempting, and the geometry refutes it — the micro-reads
  are metadata-structure fetches whose merge would either be illegal
  (non-contiguous, dependent) or already done better in-tree (W1).

**Recommendation:** keep the execution policy's merge threshold default 0
(no merging), consistent with the E5 AC-2 closure direction
(`DESIGN_CONDITIONALLY_ADMISSIBLE`, default dedup rejected). No adoption
driver from this workload. If AC-2 is ever adopted for other workloads, this
trace should be kept as a negative control: an auto-merging implementation
must refuse to merge here, not opportunistically "help".

## 4. AC-3 — explicit file-to-file copy (#607): out of scope

No file-to-file copy appears anywhere in the studied traces; the workload
cannot exercise or motivate `copy_range_at`. No driver, no counter-evidence.

## 5. DuckDB True Async host change (gate M5): no material-benefit case

R0's verdict `REQUIRES_HOST_CHANGE` stands: a synchronous wait on a DuckDB
worker is not async and must not be presented as one (dududu rule 3). This
study adds two structural facts to that verdict:

1. The T1 dependency (page-body address known only after the header-window
   parse) forbids legal overlap *within* a row group — the unit an async
   submission would most want to pipeline is dependency-chained.
2. Cross-row-group parallelism is already provided by the scan threads; the
   async ceiling is the same ~0.22–0.3 ms/query serial entry-cost figure as
   everything else here (`NO_MATERIAL_OPPORTUNITY`).

**Recommendation:** the Host Protocol Research Packet remains the correct
and only artifact for M5 in this round. No production async adapter, no
v1.5.6 patch, and no host-change contract proposal justified by this
workload — it demonstrates no material benefit that a host change would
unlock.

## 6. Next-stage admission conditions

Any future product or Host API work emerging from this research line must
satisfy all of:

1. **Workload precondition.** A trace whose seam is syscall-entry- or
   latency-dominated — many small files per query, cold scans on
   high-latency storage, or per-file metadata storms. Request geometry must
   be re-run on the new trace first, with total request attribution (this
   module's analyzer), before any adapter work.
2. **Effect-size precondition.** A pre-registered prediction above the
   recorded resolutions (W1b paired ±3–5%, W2 ±1%) before implementation or
   any formal experiment; the formal arm is then pre-registered A/A + paired
   A/B under the R0 regime (pinned cores, declared thread counts).
3. **Correctness precondition.** SQL/byte oracle before any performance
   claim (dududu rule 2); exact-count read semantics preserved; 0 short
   reads as the admission floor.
4. **Authority precondition.** No Sluice public API/ABI change without a
   v2-r1 root amendment; AC-1/2/3 stay Owner-gated design candidates — this
   study adopts none of them; any DuckDB host change stays gated on an
   Owner-accepted Host Protocol Research Packet, never on a wrapper
   presented as async.
5. **Baseline precondition.** Any external coalescing/prefetch wrapper must
   demonstrate measurable benefit over the in-tree
   `prefetch_all_parquet_files` baseline on the proposed workload — on this
   workload that baseline already captures the entire legal opportunity at
   zero Sluice cost, which is why the gate returned
   `NO_MATERIAL_OPPORTUNITY`.

## 7. What would falsify these recommendations

A workload class per §6.1 whose measured request geometry shows (a) a legal
coalescible or repeat structure, (b) quantified savings above the recorded
noise resolutions, and (c) wall-clock transfer confirmed by a pre-registered
paired experiment. Any such result re-opens the gate per
[DUCKDB_METADATA_OPPORTUNITY_GATE.md](DUCKDB_METADATA_OPPORTUNITY_GATE.md)
§9 — with new geometry, not with an adapter.

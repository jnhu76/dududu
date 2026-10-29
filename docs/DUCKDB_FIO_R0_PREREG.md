# DUCKDB_FIO_R0_PREREG — #578 R0 verdict and next-owner-gate preregistration

Date: 2026-10-29. Scope: Sluice E5 closure workflow §8.5 (R5, issue
[Sluice #578](https://github.com/jnhu76/Sluice/issues/578)). Host: E5
(Fedora 44, kernel 7.2.11-200.fc44.x86_64, Xeon E5-2666 v3, 20 CPUs, 62 GB,
btrfs `/dev/sda3[/home]` `rw,relatime,compress=zstd:1,ssd,discard=async,
space_cache=v2`, governor `schedutil` unchanged, `perf_event_paranoid=2`).

This document is the R0 **measurement and admission** record. It is **not an
application acceleration claim**: no Sluice adapter was built, no public API
was adopted, no benchmark of an alternative transport was run, and nothing
here changes the v2-r1 contract. What it delivers is the native floor, the
oracle set, the characterized noise, the located read seam and the async host
boundary that the next owner gate needs.

Companion records (Sluice research tree,
`research/direct-beyond-parity/closure/`): `r5-prep.md` (protocol freeze),
`r5-native/` (serial-lane raw evidence — kept out of dududu git per rule 6),
`r5-async-host.md` (§8.4 async admission). In-repo counterparts:
`benchmarks/fio-r0/` (frozen fio protocol), `benchmarks/duckdb-r0/`
(oracle, protocol, prep receipts, async-host probe),
`benchmarks/duckdb-r0/results/lane-record.md` (measurement-lane completion
receipts). Labeling: `[RUN]` =
executed on E5 this campaign; `[TRANSCRIBED]` = copied from a committed record
with source named; every unexecuted item is `NOT_RUN_WITH_REASON`.

## Verdict

`R0_READY_FOR_NEXT_OWNER_GATE`

fio and DuckDB native baselines are real, both oracles pass, A/A noise is
characterized with ≥15 pairs on every workload of record, the synchronous
FileSystem read seam is located and symbolized end to end, and the true-async
host protocol boundary is established (not present in v1.5.6;
`REQUIRES_HOST_CHANGE`). Remaining gaps are recorded below and none blocks the
gate.

---

## §8.5 question 1 — Is the fio native baseline real?

**Yes [RUN].** fio 3.40 (`fio-3.40-3.fc44`, Fedora 44 official repo), kernel
7.2.11, on the six frozen sections of `dududu benchmarks/fio-r0/`
(engine psync/libaio/io_uring × iodepth 1/32 × bs 4k/1M × randread/seq/randrw
75:25 × direct/buffered × dataset), all `--parse-only` validated at prep
(`benchmarks/fio-r0/README.md`). Formal runs 09:29–09:55 +08:00, exclusive
serial lane, per-run load recorded (`r5-native/fio/run-log.md`); datasets
3 × 8 GiB `/dev/urandom`, per-run SHA-256 recorded
(`r5-native/01-fio-dataset.md`): `r0-rand-8g.bin 31547d63…`,
`r0-seq-1m.bin 11383c8e…`, `r0-randrw-8g.bin 15f564a4…` → `77c4abda…` after
the randrw rounds (README-predicted mutation, read datasets unaffected).
Sections are distinct loads; no number is compared or aggregated across
sections.

Baseline (read side, settled rounds — full table in `r5-native/01-fio-dataset.md`):

| Section | settled IOPS / MiB/s | lat p50 | settled adjacent pair |
|---|---|---|---|
| r0-sync-4k-direct | 3298–3346 / 12.9–13.1 | 268–276 µs | +1.4% |
| r0-sync-4k-buffered (warm) | 3236–3311 / 12.6–12.9 | 277–293 µs | +2.3% |
| r0-sync-4k-buffered-cold (drop_caches) | 3236–3284 / 12.6–12.8 | 277–285 µs | −1.5% |
| r0-libaio-4k-qd32-direct | 4002–4058 / 15.6–15.9 | 7.63–7.70 ms | +1.4% |
| r0-io_uring-4k-qd32-direct | 3990–3994 / 15.6 | 7.70 ms | −0.1% |
| r0-seqread-1m-direct | 383–389 MiB/s | 2.54 ms | −1.7% |
| r0-randrw-4k-r75-direct | 1139–1444 IOPS (2 rounds) | 277–322 µs | +26.8% (under-sampled) |

Disclosures: round 1 of every section ran immediately after the 24 GiB dataset
allocation and is the slow sample (QD32 p99 ~290–300 ms vs ~9 ms settled);
raw JSONs keep it, the settled statements exclude it
(`r5-native/01-fio-dataset.md`, "Outlier disclosure"). randrw mutates its
dataset per run and has only 2 rounds — recorded as under-sampled, no baseline
claim. fio A/A is n=2–3 per section: baseline identity + pair-noise
characterization, **no hypothesis-test power claim**.

## §8.5 question 2 — Is the DuckDB native baseline real?

**Yes [RUN].** Binary = SHA-scoped upstream build
`build/duckdb-native/069cc9f9b5be802405797faecc284961b07c70ef/duckdb` +
`benchmark_runner` (upstream CMake options only, no patch; GCC 16.2.1).
Submodule HEAD = `069cc9f9…` = remote `refs/tags/v1.5.6` (prep
`git ls-remote`, prep-record). Known display artifact: `duckdb --version`
prints `v0.0.1 (Unknown Version) 069cc9f9` — depth-1 checkout without the tag
object (two tag fetches failed in prep due to network); identity rests on the
SHA, which equals the v1.5.6 tag ref. Dataset:
`lineitem.parquet`, 207,130,013 B, SHA-256
`b7583e65198aaa9522067fd849f9d08f2668df2e7608fef548ab386cab0ef911`,
re-verified at lane start. Harness: official
`benchmark/tpch/parquet/parquet_projection_direct.benchmark` through the
upstream `benchmark_runner`, plus the 4-query SQL oracle
(`benchmarks/duckdb-r0/oracle.sql`). Prep entry-point gate: `ctest -R duckdb`
5/5 passed (prep-record).

## §8.5 question 3 — Is the A/A noise acceptable?

**Yes for the configurations of record [RUN].** Three pre-declared workloads,
serial lane, per-invocation oracle gate (exit code + INCORRECT scan for the
runner; CSV hash equality for W2), sleep 1 s between invocations
(`r5-native/02-duckdb-oracle-aa.md`; raw `r5-native/duckdb/aa-w1/`,
`aa-w1b/`, `aa-w2/`):

| Workload | config | invocations / pairs | mean | CV | adjacent-pair mean / max |
|---|---|---|---|---|---|
| W1 | official benchmark, upstream default (20 threads, all cores) | 30 / 29 | 20.813 ms | 7.39% | 8.71% / 23.87% |
| W1b (**of record**) | official benchmark, `taskset -c 2-9 --threads=4` | 30 / 29 | 35.887 ms | 4.46% | 4.90% / 13.86% |
| W2 | 4-query oracle suite via CLI, whole-process wall, `taskset -c 2-9` | 16 / 15 | 0.296 s | 1.67% | 1.49% / 4.08% |

73 A/A pairs total; the ≥15-pair requirement (§8.3) is met on every workload.
fio settled pair spreads ≤2.3% (question 1). Statistical limits, honestly
stated: with W1b's observed pair noise, a paired A/B at n=15 resolves effects
of roughly **±3–5%**; the W2 suite resolves roughly **±1%**; smaller effects
need more pairs or the W2-style workload. There is **no power analysis against
a preregistered effect size** — the MDE statements derive from observed pair
noise. The unpinned default config (W1: CV 7.39%, max pair 23.87%) is recorded
as the noise regime any future A/B must avoid by pinning cores and declaring
thread counts. No A/B was run in R0 (§8.3 scopes R0 to the noise assessment).

Page-cache timing impact [RUN, `r5-native/duckdb/cold-timing/`]: first repeat
after `drop_caches` pays ≈ +25–40% (8–14 ms) over warm steady state; by the
third repeat timing is back inside the warm band. `drop_caches` was executed
under the measurement ask's sudo grant, logged in `r5-native/00-environment.md`
(supersedes the prep-phase authorization blocker).

## §8.5 question 4 — Do the SQL and byte oracles pass?

**Yes [RUN].**

- SQL oracle: `oracle.sql` lane-r1 and lane-r2 — all four CSV SHA-256s
  byte-identical across the two runs and equal to the committed prep-record:
  q1 `54adfd20…`, q2 `6b7830dd…`, q3 `673ce9f4…`, q4 `26788f24…` (full hashes
  in `r5-native/02-duckdb-oracle-aa.md` and
  `benchmarks/duckdb-r0/results/prep-record.md`). q2 returnflag groups match
  canonical TPC-H sf=1 (A/F 1,478,493 · N/F 38,854 · N/O 3,004,998 · R/F
  1,478,870; 6,001,215 rows total). Small CSVs archived
  `r5-native/duckdb/oracle-csv/`.
- Byte/value oracle: the official benchmark's upstream `result` oracle
  (`226829357828.867781`; v1.5.6 prints a `…\tINCORRECT` line on mismatch,
  `third_party/duckdb/benchmark/benchmark_runner.cpp:122`) passed with
  **zero INCORRECT across all 62 benchmark-runner invocations** in the lane
  (30 W1 + 30 W1b + 2 cold-timing); the CLI aggregate printed the exact
  expected value in the strace runs.

## §8.5 question 5 — Is the sync FileSystem read seam located?

**Yes — located and symbolized [RUN].** `strace -k` around the official
aggregate query shows, for both ~634 KB data reads and 256 B metadata reads,
the same synchronous chain (`r5-native/duckdb/io-trace-kstack.txt`;
`r5-native/03-duckdb-io-exposure.md`):

```
pread(2) ← LocalFileSystem::Read(FileHandle&,…) ← ThriftFileTransport::read
← ParquetReader::ReadData ← ColumnReader::PreparePage/PrepareRead/
ReadPageHeaders/ReadInternal ← ParquetReader::Scan
← MultiFileFunction<ParquetMultiFileInfo>::MultiFileScan
← PhysicalTableScan::GetDataInternal ← PipelineExecutor::FetchFromSource/Execute
```

matching `docs/duckdb-stable-io-map.md` §1.1. Facts:

- Cold = warm request stream **byte-identical** (492 `pread64`,
  37,172,128 B, 0 short reads / 0 zero-byte returns in both runs) — the page
  cache changes latency, not the request stream. 37.17 MB = 17.9% of the file
  (projection pushdown).
- Size histogram: 49 × ~634.5–634.7 KB (83.4% of bytes, row-group column
  chunks), 98 × ~61.9 KB, 1 × 79,613 B footer, 344 × ≤4 KiB totalling 48,674 B
  — **70% of all calls move 0.13% of the bytes** (147 × 256 B page headers +
  46–68 B thrift tails).
- Per-column: `SUM(l_extendedprice)` 100 preads / 31,086,130 B;
  `SUM(l_discount)` 198 / 3,123,007 B; `COUNT(*)` 2 / 79,621 B (metadata
  floor). Each scan thread opens its own fd (28–31 `openat`s, all `O_RDONLY`).
- Alignment: all traced reads are unaligned in offset and/or length
  (e.g. offset mod 512 = 467, size mod 512 = 266) — **none can pass through
  `O_DIRECT` as-is**.
- Operator attribution (built-in `query_tree` profiler,
  `r5-native/duckdb/query-profile.txt`): scan-dominated — TABLE_SCAN ≈ 0.33
  thread-seconds vs ≈ 0.033 s wall at 20 threads.
- Kernel-level perf hotspot attribution: **NOT_RUN_WITH_REASON** —
  `perf_event_paranoid=2` denies unprivileged `cycles:u` ("Failure to open any
  events for recording"); relaxing a security setting exceeded the
  measurement-permission sudo grant and was not attempted. User-space seam
  evidence obtained via `strace -k` + built-in profiler; instruction-level
  attribution is missing.

## §8.5 question 6 — Is a sync Direct adapter admissible?

**The sync seam is the only production I/O form and is admissible as such
(R0 D2 scope); a Direct-I/O (O_DIRECT) adapter has no demonstrated win on this
host and this workload, and is not claimed.** Evidence:

1. fio shows 4k random reads are **not page-cache-bound and not
   direct-improved** on this btrfs stack: direct ≈ buffered ≈ cold-buffered
   (~3.2–3.3k IOPS, within ±2.3% pair noise). There is no hidden device
   performance behind the page cache at this shape. The only bandwidth-bearing
   shape is large sequential reads (~330–389 MiB/s).
2. DuckDB's reads are already large and projection-pruned (83.4% of bytes in
   49 × ~634 KB reads, 0 short reads) — the storage-side shape is already the
   good shape.
3. `O_DIRECT` is not issuable on the observed stream without bounce-buffer
   realignment (alignment facts, question 5), and fio says the device offers
   no 4k-random win to pay the copies with. Warm cache removes 8–14 ms
   (+25–40% on the first post-drop query); direct I/O would forfeit caching
   for no observed small-I/O benefit.
4. The **real, measured lever is syscall/metadata traffic, not cache policy**:
   70% of preads (344/492) are ≤4 KiB metadata reads moving 0.13% of bytes; a
   per-call tax lands on the scan thread critical path. This is the shape an
   AC-1-style vectored read or metadata-batch seam targets. Detectability
   bounds: an A/B of such a mechanism must show ≥~5% on the pinned benchmark
   workload (n=15) or ≥~1% on the oracle-suite workload. This is an
   **experimental recommendation for the next owner gate, not an adopted
   API** and not an acceleration result.

## §8.5 question 7 — Does the true-async host protocol have a legal completion-driven boundary?

**No [RUN + TRANSCRIBED] — `REQUIRES_HOST_CHANGE`.** Full analysis:
`r5-async-host.md`. Summary:

- The §8.4-named `ReadAheadIOTask`/`ScanReadAhead`/`ReadAheadJobCompletion`
  **do not exist in v1.5.6** (full-tree sweep, 0 hits — #556 v2.0-dev
  lineage); the actual counterparts are the synchronous parquet
  `ReadAheadBuffer` and the `AsyncTask`/`AsyncResult` protocol.
- Completion accounting is bound to **task return**
  (`AsyncExecutionTask::ExecuteTask` decrements the batch counter when the
  task function returns, `async_result.cpp:34-40`); there is no pending task
  state, no failure channel, and no external completion driver (all production
  `InterruptState::Callback` drivers are in-process events).
- Non-invasive probe [RUN], dududu branch `r5-async-host-probe` @ `4eafbc0`
  (based on `sluice-r0-closure` @ `cc053cf`), deterministic assertions, no
  sleep synchronization, 1/1 + 5/5 stability reruns exit 0:
  **P1** early-return task → counter hits zero while data is still poisoned —
  garbage chunk handed to the pipeline, not admissible; **P2** submit+wait →
  single worker pinned for the full 3.006 ms wait inside the task body,
  queued tasks starve — correct but not completion-driven; **P3**
  `TASK_BLOCKED` → descheduled once, never revived after queue drain — no
  scheduler-level pending state.
- Three-way classification: **Sync Direct** = admissible (v1.5.6's only
  production form); **Submit+Wait wrapper** = correct but NOT true async (one
  DuckDB worker pinned per in-flight I/O; explicitly excluded by §8.4 and
  dududu AGENTS rule 3); **true completion-driven async** =
  `REQUIRES_HOST_CHANGE`, consistent with `docs/duckdb-stable-io-map.md`
  §2.4 (D3/D4), now backed by machine evidence. Host-change minimal form is
  listed in `r5-async-host.md` §10 (three-state task contract or
  non-decrementing task kind; `InterruptState` as external resume token;
  non-worker fixed progress owner; cancellation borrowed-pointer
  re-proof; D0' control arm as attribution precondition).

## §8.5 question 8 — What adaptation and experiments belong to the next stage?

**Preregistration for the next owner gate** (nothing here is adopted; owner
decides):

1. **Candidate mechanism class**: a vectored / metadata-batch read seam
   (AC-1-shaped) that removes the 344 ≤4 KiB per-read metadata calls —
   explicitly **not** a Direct-I/O adapter and not an O_DIRECT path; the fio
   baseline refutes the O_DIRECT value hypothesis on this stack.
2. **Oracle first**: every timed invocation gated on the upstream `result`
   oracle (zero INCORRECT) and/or the 4-query SQL CSV hash equality — the
   gate is never weakened to make a timing number pass.
3. **Workloads and thresholds**: W1b (`taskset -c 2-9 --threads=4`, resolves
   ≥~5% at n=15) and/or the W2 oracle-suite wall (resolves ≥~1%); ≥15 pairs;
   exclusive serial lane; settling pass before formal runs (the fio round-1
   post-allocation hysteresis is the recorded lesson); pin cores and declare
   thread counts (the W1 noise regime is the recorded anti-pattern).
4. **Async**: no adapter work may present wait-based wrapping as async. True
   async requires the host changes of `r5-async-host.md` §10 with the D0'
   control arm; any such step is an owner decision, not this campaign's.
5. **Out of scope for any next stage without a root amendment**: new public
   Sluice API adoption (AC-1/2/3 remain ADR/prototype/decision material),
   v2-r1 contract changes, and upstream DuckDB patches.

## NOT_RUN_WITH_REASON and residual gaps (none gate-blocking)

| Item | Status | Reason / gap |
|---|---|---|
| Kernel-level perf hotspot attribution | NOT_RUN_WITH_REASON | `perf_event_paranoid=2` blocks unprivileged `cycles:u`; relaxing a security setting was outside the measurement authorization. User-space seam evidence obtained instead (`strace -k`, built-in profiler). |
| `duckdb --version` display string | known artifact | prints `v0.0.1 (Unknown Version) 069cc9f9` (depth-1 tag object missing after prep network failures); identity is the SHA = remote `refs/tags/v1.5.6`; fetching the tag + reconfigure restores the string when network allows. |
| fio A/A per-section depth | disclosed limitation | n=2–3 (baseline identity + pair noise, no power claim); randrw 2 rounds on a mutating dataset, under-sampled. |
| Power analysis vs preregistered effect size | not produced | MDE statements derive from observed pair noise; no α/effect-size preregistration existed before the A/A. |
| Raw-evidence git archive | pending R1/R9 flow | `r5-native/` lives in the untracked Sluice `research/` tree; archiving it belongs to the evidence-archive flow, not this lane. Raw JSON/traces never enter dududu git (dududu AGENTS rule 6). |
| Any adapter A/B | out of R0 scope | §8.3 scopes R0 to native baseline + A/A; the A/B is the next gate's experiment (question 8). |

## Boundary declarations

- No PR was merged; the dududu R0 research PR stays OPEN.
- No new public API adopted; AC-1 remains decision material for the owner.
- v2-r1 public contract unchanged; no Sluice product code touched; frozen
  worktrees untouched.
- R0 is a **native floor + seam identity + admission boundary** result. It
  must not be cited as an application speedup of Sluice, DuckDB, or any
  adapter; no accelerated end state was measured.

## Evidence index

| Claim group | Files |
|---|---|
| Protocol freeze / prep receipts | dududu `benchmarks/fio-r0/README.md`, `benchmarks/duckdb-r0/{README.md,oracle.sql,results/prep-record.md}`, `r5-prep.md` |
| Host / sudo / lane order | `r5-native/00-environment.md` |
| fio baseline + A/A + outlier | `r5-native/01-fio-dataset.md`, `r5-native/fio/*.json`, `r5-native/fio/run-log.md` |
| DuckDB oracle + A/A + cold timing | `r5-native/02-duckdb-oracle-aa.md`, `r5-native/duckdb/aa-w1/`, `aa-w1b/`, `aa-w2/`, `cold-timing/`, `oracle-csv/` |
| I/O exposure + seam | `r5-native/03-duckdb-io-exposure.md`, `r5-native/duckdb/io-trace-*.txt`, `query-profile.txt` |
| Analysis + §8.5 answers | `r5-native/04-analysis.md` |
| Async host admission + probe | `r5-async-host.md`, dududu branch `r5-async-host-probe` (`benchmarks/duckdb-r0/async-host-probe/`) |
| Upstream oracle gate location | `third_party/duckdb/benchmark/benchmark_runner.cpp:122` (dududu checkout, pinned v1.5.6) |

# Experiment matrix

The five-arm design, its admission rules, and what each arm is allowed to claim.

## Arms

| ID | Name | Stage | Question it answers | Host change |
|---|---|---|---|---|
| D0 | Native DuckDB | R0 build + smoke | What does the unmodified release do? | none |
| D1 | Native FileSystem wrapper | R1 | What does the wrapper itself cost? | none |
| D2 | Sluice Direct | R1 | Does moving bytes through Sluice change the synchronous path? | none |
| D3 | Sluice ThreadPool, true async | R2, separate admission | Can completion-driven I/O overlap with query work? | required |
| D4 | Sluice io_uring, true async | R2, separate admission | Does kernel-level async change the same measurement? | required |
| D0' | Native Host-Refactor Control | R2, paired with D3/D4 | What does the host patch itself cost, with no Sluice? | same patch as D3/D4 |

D0' is not a sixth experiment. It is the control that makes D3/D4 attributable:
a host-protocol change is measured with the native filesystem under the identical
patch, so a D3/D4 delta cannot be credited to Sluice when it is really the patch.

## Standalone Parquet arms (R1)

Before pointing the D1/D2 machinery at DuckDB, the same three-shape
comparison runs against a second real workload: the Apache Parquet C++
reader. DuckDB is not built, modified or run for these arms.

| ID | Name | I/O implementation | Role |
|---|---|---|---|
| P0 | Arrow Native | `arrow::io::ReadableFile` | native baseline |
| P1 | Native Wrapper | custom `RandomAccessFile` + POSIX `pread` | adapter-cost control |
| P2 | Sluice Direct | same adapter + `sluice::blocking::read_at` | experiment arm |

P1 and P2 are one adapter (`experiments/parquet/src/adapter_file.cpp`) over
two interchangeable backends; each backend TU contains exactly one
byte-moving primitive, and fault injection at the backend boundary proves
the reader actually traverses it. The P-arms answer, with a second
workload, the same questions D1/D2 ask of DuckDB: what does the reader
request, what does a wrapper cost, what does Sluice's synchronous path
change. Protocol and admission: `benchmarks/parquet/protocol.md`.

| ID | Status | Evidence |
|---|---|---|
| P0 | **PASS (R1 scope)** | oracle-equal decode, all workloads; request profile via trace/strace |
| P1 | **PASS (R1 scope)** | contract + oracle + fault-injection evidence; wrapper tax measured |
| P2 | **PASS (R1 scope, warm-cache synchronous)** | contract + oracle + fault-injection evidence; sluice effect measured; replay cross-check |

## Current status

| ID | Status | Evidence |
|---|---|---|
| D0 | **PASS (R0 scope)** | unmodified v1.5.6 build; shell, unittest, benchmark entry points executed |
| D1 | not started | directory + README only |
| D2 | not started — admission candidate | `docs/duckdb-stable-io-map.md` §1.5 |
| D3 | blocked on host change | `docs/duckdb-stable-io-map.md` §2.4 |
| D4 | blocked on host change | `docs/duckdb-stable-io-map.md` §2.4 |
| D0' | design only | `docs/duckdb-stable-io-map.md` §2.5 |

"No result" is the correct state for D1–D4. Nothing in R0 measures them.
The P-arms above are the R1 standalone round; their numbers are bound to
their protocol (`benchmarks/parquet/protocol.md`) and do not transfer to
DuckDB or to conditions outside it (cold cache, async, other hosts).

## Admission rules

An arm may produce a performance number only after all of the following hold:

1. **Correctness admission first.** The arm's output must match D0 for the same
   SQL and dataset, through a correctness oracle (DuckDB's `result` statements
   in benchmarks, `sqllogictest` files, or a checksum of the result set). A
   speedup measured against a wrong answer is not a result.
2. **Semantics admission.** The arm must satisfy the host contract it plugs into.
   For D2 that includes the `FileHandle::Read` exact-count-or-throw rule
   (`docs/duckdb-stable-io-map.md` §1.3). A short-read adapter that silently
   returns fewer bytes fails admission, it does not "mostly work".
3. **True-async proof.** D3/D4 must demonstrate *overlap*: at least one query
   in flight whose I/O is outstanding while a DuckDB worker is executing query
   work, with the host worker count held fixed. A synchronous wait inside
   `AsyncTask::Execute()` is not overlap and cannot be reported as such.
4. **Dual SHA.** Every result carries `DUDUDU_SHA`, `SLUICE_SHA`,
   `DUCKDB_TAG`/`DUCKDB_SHA`, build profile, and SDK prefix identity.
5. **Paired, single-factor.** Baseline and candidate run on the same host, same
   binary layout, same dataset, same SQL, same cache state, alternating order.
6. **Official entry points only.** Results come from DuckDB's `test/unittest`
   and `benchmark/benchmark_runner`, or from a benchmark registered in the
   official framework. No ad-hoc `std::chrono` loops.

## Dimensions that must be frozen per run

- DuckDB source SHA (and whether it is patched — D3/D4/D0' only).
- Sluice baseline SHA and candidate SHA; which profile (`noliburing` /
  `liburing`) each side links.
- CMake/xmake configuration, compiler and flags, build directory, SDK prefix.
- Cache state: external file cache on/off, OS page cache cold/warm, dataset
  preparation step.
- Dataset, generated scale factor, SQL text, query plan (`EXPLAIN` captured).
- CPU affinity/allowed cores, memory limit, I/O concurrency budget.
- Bytes read and achieved in-flight depth (measured, not assumed); for D2 this
  is "bytes Sluice actually served", not "bytes the query logically touched".

## What each arm may not claim

- D1 may not claim a Sluice effect; it exists to subtract wrapper cost.
- D2 may not claim overlap; its execution is completed-return by construction.
- D3/D4 may not claim a result before D0' exists for the same host patch.
- No arm may claim a result from build success, from a single run, or from a
  different dataset than the baseline.

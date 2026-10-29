# async-host-probe — DuckDB v1.5.6 task/async-host protocol probe

Sluice #578 R5 §8.4 (Async Host Admission) evidence. This probe is
**non-invasive**: no DuckDB source, submodule or bridge file is modified. It
links a standalone TU against the prebuilt, SHA-pinned `libduckdb` and drives
the real `duckdb::TaskScheduler` with three deterministic probes that
characterize the boundary between synchronous execution, submit+wait wrapping,
and completion-driven async.

Probes (all asserts are on atomic happens-before edges or one-worker queue
semantics; no assertion depends on timing):

- **P1 early-return task** — submits external I/O and returns before
  completion. Mirrors `AsyncExecutionTask`'s accounting
  (`src/parallel/async_result.cpp:34-40`): the completion counter fires on task
  RETURN. Observed: the resume edge fires while the I/O is in flight and the
  destination buffer still holds poisoned bytes. An early-return task kind
  would hand the pipeline a garbage chunk → inadmissible without host support.
- **P2 submit-and-wait task** — submits and blocks its executing thread until
  external completion. Observed: correct data, but the single scheduler worker
  is pinned for the whole wait (≈ the simulated latency window) and a task
  queued behind it cannot start. This is the submit+wait sync wrapper, not
  completion-driven async.
- **P3 TASK_BLOCKED task** — returns `TASK_BLOCKED` on the plain scheduler.
  Observed: executed once, descheduled, queue drained, never revived by any
  scheduler-internal driver. Revival is Executor-owned
  (`ExecutorTask::Deschedule` → `Executor::AddToBeRescheduled`; resumption via
  `InterruptState::Callback` → `Executor::RescheduleTask`), and v1.5.6's
  production Callback drivers are all in-process (aggregate partition handoff,
  batch memory manager, debug test tasks).

## Identity

- DuckDB: tag `v1.5.6`, SHA `069cc9f9b5be802405797faecc284961b07c70ef`
  (submodule HEAD, porcelain clean).
- Library: `build/duckdb-native/069cc9f9b5be802405797faecc284961b07c70ef/src/libduckdb.so`
  (upstream CMake, release profile; see `docs/r5 prep receipts` in the R0 prep
  record — no patch, SHA-scoped directory).
- Host: E5 (Fedora 44, kernel 7.2.11-200.fc44.x86_64, GCC 16.2.1).
- dududu: branch `r5-async-host-probe` (based on `sluice-r0-closure`).

## Build and run

```sh
DUCKDB_SHA=069cc9f9b5be802405797faecc284961b07c70ef
DB=build/duckdb-native/$DUCKDB_SHA
g++ -std=c++17 -O1 -pthread \
  -I third_party/duckdb/src/include \
  -I third_party/duckdb/third_party/libpg_query/include \
  -I $DB/third_party/libpg_query/include \
  benchmarks/duckdb-r0/async-host-probe/async_host_probe.cpp \
  -L $DB/src -lduckdb -o /tmp/async_host_probe
LD_LIBRARY_PATH=$DB/src /tmp/async_host_probe   # exit 0 = all probes as predicted
```

Expected output ends with `ALL PROBES BEHAVED AS PREDICTED (exit 0)`.

## Result

Observed on E5 on 2026-10-29: 1/1 initial run plus 5/5 stability runs, all
exit 0 with the verdicts above. [RUN]

## Admission consequence

- Sync Direct (caller-thread I/O, or `AsyncResult::ExecuteTasksSynchronously`,
  or `TaskExecutor::WorkOnTasks`): works today, no host change.
- Submit+Wait (blocking wait inside `AsyncTask::Execute()`): functionally
  correct but pins one DuckDB worker per in-flight I/O — per the R5 admission
  rule this is NOT true async.
- True completion-driven async (task returns before completion; an external
  completion owner drives the resume): requires a host change — a task kind
  that does not decrement the batch counter on return, plus a resumption
  driver reachable from outside the query's own workers.

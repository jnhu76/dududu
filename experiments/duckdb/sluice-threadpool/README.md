# D3 — Sluice ThreadPool, true async

Status: **R2. Not implemented. Host admission: `REQUIRES_HOST_CHANGE`.**

Why blocked: `AsyncTask::Execute()` is a synchronous `void` call and DuckDB counts
the task complete the moment it returns
(`third_party/duckdb/src/parallel/async_result.cpp:27-47`). A task that only
submits to Sluice would fire `InterruptState::Callback()` before the I/O
finished; a task that blocks until completion occupies a DuckDB worker. Neither
is true async, so this arm cannot be built against the unmodified host.

Admission requires, in order:

1. a host change that lets a task complete through an explicit token instead of
   on return (design in `docs/duckdb-stable-io-map.md` §2.5),
2. **D0'** — the same host patch measured with the native filesystem,
3. a correctness oracle equal to D0 on the same workload,
4. an overlap demonstration at fixed worker count.

Until all four exist, this arm has no result and must say so.

# D4 — Sluice io_uring, true async

Status: **R2. Not implemented. Host admission: `REQUIRES_HOST_CHANGE`.**

Same task-contract limit as D3 (`docs/duckdb-stable-io-map.md` §2.4), plus one
extra requirement: Sluice's io_uring execution has a **single fixed progress
owner** that drives `poll_progress()`/`wait_one()` and owns the notification fd.
DuckDB's `Executor`/`TaskScheduler` has no place to host that owner, and parking
a DuckDB worker in `wait_one()` is explicitly not acceptable.

Additional preconditions before this arm may run:

- D3's host change is settled (D3 and D4 must not be admitted against different
  host patches),
- the progress owner is a dedicated thread outside the DuckDB worker pool,
- `liburing=y` is the linked profile on both sides of any comparison, verified by
  the SDK profile checks (`sluice.sdk.async.uring`, `nm -u` on the archive),
- a ring-setup failure is reported as `NOT_SUPPORTED`, never silently routed to
  ThreadPool.

The environment for R0 does support io_uring: `sluice.sdk.async.uring` performs a
real ring round-trip on this host. That is a capability statement only — it is
not evidence about D4 performance.

# D2 — Sluice Direct

Status: **R1. Not implemented. Host admission: `HOST_ADMISSION_CANDIDATE`.**

A `FileSystem`/`FileHandle` adapter that moves bytes with Sluice's direct
completed-return operations (`sluice::blocking::read_at`, `read_exact`) while
keeping DuckDB's existing synchronous scan structure.

Open design questions that R1 must settle before writing code:

- Every parquet read in v1.5.6 goes through `CachingFileSystem`
  (`docs/duckdb-stable-io-map.md` §1.2); the adapter sits below it and will not
  see cache hits. What is the honest denominator for "bytes Sluice served"?
- `FileHandle::Read` requires exactly-N-or-throw while `read_at` returns a byte
  count. Which composition is used, and does it change short-read behaviour at
  EOF? (`docs/duckdb-stable-io-map.md` §1.3)
- Does the two-level caching stack (`CachingFileSystem` +
  `CachingFileSystemWrapper` on cached open flags) need to be disabled for a
  comparable measurement, and is disabling it a host change?

D2 has two sub-modes to keep separate in any result table: with DuckDB's
parquet prefetch enabled and with it disabled (`disable_parquet_prefetching`).
They are different I/O patterns and must not be pooled.

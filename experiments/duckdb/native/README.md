# D0 — Native DuckDB baseline

Status: **R0 build + smoke only.**

Unmodified DuckDB at the pinned stable release, built by `cmake/DuckDB.cmake`
through its own CMake project. No source change, no extra defines beyond the
documented options in `docs/build-boundary.md`.

Provides:

- the reference binaries (`duckdb`, `test/unittest`, `benchmark/benchmark_runner`),
- the correctness oracle for every other arm,
- the performance baseline.

Not yet present: any adapter code. This directory stays empty until an experiment
needs an arm-specific file; a placeholder source tree here would be a fake
implementation.

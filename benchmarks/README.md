# Benchmarks

Experiments are measured **only** through official facilities:

- `third_party/duckdb/benchmark/benchmark_runner` (registered benchmarks, with
  upstream `result` oracles and JSON output via `--out=`),
- `third_party/duckdb/test/unittest` (SQL logic tests),
- `ctest` targets in `tests/CMakeLists.txt` for entry-point smoke.

No custom timing loop exists in R0 and none should be added casually. A new
workload has to be registered in DuckDB's benchmark framework (or expressed as a
sqllogictest) so it carries a correctness oracle and the same execution path as
the baseline.

Artifacts (`--out=` JSON, raw logs) go under the ignored `build/` or `results/`
directory. They are evidence, not source.

R0 smoke currently registered:

| CTest name | What it runs |
|---|---|
| `duckdb.shell.smoke` | `SELECT 42` plus a Parquet write/read round-trip |
| `duckdb.unittest.smoke` | one official sqllogictest through `test/unittest` |
| `duckdb.benchmark.list` | `benchmark_runner --list` (tpch + parquet present) |
| `duckdb.benchmark.smoke` | `benchmark/tpch/parquet/parquet_projection_direct.benchmark` (slow, labelled `slow`) |

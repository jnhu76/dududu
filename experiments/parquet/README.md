# experiments/parquet — standalone Parquet × Sluice (R1)

Three arms decode the same real Parquet files with the real
`parquet::arrow` reader:

* **P0 arrow-native** — `arrow::io::ReadableFile`, untouched.
* **P1 native-wrapper** — one custom `RandomAccessFile` over POSIX `pread`.
* **P2 sluice-direct** — the same adapter over `sluice::blocking::read_at`
  from dududu's installed Sluice SDK (`Sluice::core`, `noliburing`).

DuckDB is absent by design in this experiment: no DuckDB build, no DuckDB
adapter, no submodule change. This is a standalone workload round that
feeds the same attribution discipline the D-arms will use later.

## Layout

    CMakeLists.txt        opt-in targets (DUDUDU_ENABLE_PARQUET, preset 'parquet')
    include/dududu/parquet/
      io_backend.hpp        backend seam + shared arg contract + counters
      adapter_file.hpp      the one RandomAccessFile over any backend
      io_decorators.hpp     counting / tracing / fault-injection / fake backends
      reader_config.hpp     frozen reader settings (pre_buffer=false, all arms)
      fixture.hpp           deterministic dataset generator
      oracle.hpp            canonical decode digest (the admission gate)
      runner.hpp            workloads T1/T2/T3 with identical phase boundaries
      io_trace.hpp          request-trace capture + I/O-only replay
      sha256.hpp            FIPS 180-4, manifest + oracle digests
    src/                    backends, adapter, decorators, generator, oracle,
                            runner, trace/replay, tool mains
    tests/                  parquet.contract / parquet.oracle / parquet.trace

## Build and test

    cmake --preset parquet
    cmake --build build/cmake-parquet --parallel 4
    ctest --test-dir build/cmake-parquet -R parquet --output-on-failure --parallel 1

Needs system `libarrow-dev`, `libparquet-dev`, `libbenchmark-dev
(1.9.1)`. Missing packages fail the configure loudly.

## Benchmarks

    bash benchmarks/parquet/run-bench.sh both     # protocol: warm pass + sampled pass
    bash benchmarks/parquet/summarize.sh build/parquet-results/measure-pass.json

Protocol, frozen configurations, dataset SHAs, attribution rules and host
disclosure: [`benchmarks/parquet/protocol.md`](../../benchmarks/parquet/protocol.md).
Results and their schema: [`benchmarks/parquet/results-schema.md`](../../benchmarks/parquet/results-schema.md).

## Invariants worth knowing before touching this

* Correctness admission precedes performance: an arm that has not matched
  P0's oracle digest produces no number.
* The arms share one adapter; only the backend differs, and each backend TU
  contains exactly one byte-moving primitive (checkable with `nm`).
* `pre_buffer=false` is global; turning it back on silently changes the
  observed request stream to one coalesced whole-file read.
* No sleep anywhere; concurrency is proven by real concurrent reads.
* Legal EOF is a zero-byte success on both arms; no backend error may
  surface as one.

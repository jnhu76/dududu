# dududu

Experiment harness for using **DuckDB as a real workload for [Sluice](https://github.com/jnhu76/Sluice)**:
find I/O bottlenecks with DuckDB's own tests and benchmarks, compare DuckDB's
native I/O against Sluice's execution models, attribute differences to
mechanisms, and only then propose a Sluice change with evidence.

R0 (this state) builds the foundation: pinned upstreams, a working Sluice SDK
bridge, an unmodified DuckDB baseline, and a source-level map of DuckDB's stable
I/O path. **No performance conclusion is drawn in R0.**

## Five-arm design

| ID | Arm | Stage |
|---|---|---|
| D0 | Native DuckDB | R0: build + smoke |
| D1 | Native FileSystem wrapper (adapter-cost control) | R1 |
| D2 | Sluice Direct | R1 |
| D3 | Sluice ThreadPool, true async | R2, separate admission |
| D4 | Sluice io_uring, true async | R2, separate admission |
| D0' | Native Host-Refactor Control for D3/D4 | R2 |

Details and admission rules: [`docs/experiment-matrix.md`](docs/experiment-matrix.md).

## Requirements

- Linux (io_uring work is Linux-only; Windows/macOS are **not** supported or
  verified here).
- C++20 compiler (verified with GCC 15.2), CMake ≥ 3.24, Ninja, xmake ≥ 3.0.
- Python 3 only if you choose to run Sluice's own package verifier.
- `liburing-dev` for the `liburing=y` profile.

Verified host for R0: Ubuntu 26.04 (WSL2), kernel 6.18.54.1,
GCC 15.2.0, CMake 4.2.3, Ninja 1.13.2, xmake 3.1.2, liburing 2.14.

## Upstream pinning

Two submodules, pinned to full SHAs. No floating branches in an experiment.

```
third_party/sluice   https://github.com/jnhu76/Sluice    origin/master @ 8fdcd99c5f9a42dadfe5aa0c095bf96c756aeb01
third_party/duckdb   https://github.com/duckdb/duckdb   v1.5.6       @ 069cc9f9b5be802405797faecc284961b07c70ef
```

```bash
git clone --recurse-submodules <this repo>
# or, in an existing checkout:
git submodule update --init --recursive
```

Rules:

- Once an experiment is frozen, submodules are not updated automatically.
- Upgrading a dependency is an explicit commit that records old SHA → new SHA and
  re-verifies build + correctness.
- The DuckDB SHA is the tag's commit, not the release page's `target_commitish`.

## Build and test

```bash
# Configure (Ninja, Release)
cmake -S . -B build/cmake -G Ninja -DCMAKE_BUILD_TYPE=Release

# Sluice SDK + consumer smoke tests (fast)
cmake --build build/cmake --target sluice_core_consumer sluice_threadpool_consumer \
                            sluice_uring_consumer sluice_uring_absence
ctest --test-dir build/cmake -R sluice --output-on-failure

# DuckDB native baseline (unmodified upstream CMake; ~17 min on 8 cores)
cmake --build build/cmake --target duckdb_native -j8

# DuckDB entry points
ctest --test-dir build/cmake -R duckdb --output-on-failure -E "benchmark.smoke"
ctest --test-dir build/cmake -R duckdb.benchmark.smoke --output-on-failure   # ~10 min, TPC-H sf=1
```

`sluice-only` preset skips the DuckDB build (`cmake --preset sluice-only`).

### Sluice SDK

Sluice is built by **its own xmake project**, never by a second CMake definition:

```bash
# what cmake/Sluice.cmake does, per profile
cd build/sluice-work/noliburing
xmake f -P ../../../third_party/sluice -m release --liburing=n -y --builddir=$PWD/out
xmake -y sluice_core && xmake -y sluice_async
xmake install -o ../../sluice-stage/noliburing sluice_core
xmake install -o ../../sluice-stage/noliburing sluice_async
```

The SDK prefix is `build/sluice-sdk/{noliburing,liburing}` and holds exactly the
11 contracted headers plus `libsluice_core.a` and `libsluice_async.a`.
Consumers link in GNU order: `-lsluice_async -lsluice_core [-luring]`.

CMake exposes dududu-local imported targets `Sluice::core`, `Sluice::async`,
`Sluice::core_uring`, `Sluice::async_uring`. These are **not** an upstream CMake
package — Sluice exports none.

### DuckDB native benchmark smoke

```bash
cd build/duckdb-native
./benchmark/benchmark_runner --list | head
./benchmark/benchmark_runner \
    --benchmark=benchmark/tpch/parquet/parquet_projection_direct.benchmark \
    --out=/tmp/bench.json
```

## Boundaries

- **R0** — repository, submodules, build boundary, SDK consumption, DuckDB
  baseline, I/O call-chain audit. No adapter, no optimisation, no verdict.
- **R1** — D1 and D2 implementations behind correctness admission.
- **R2** — D3/D4, which require a host change and therefore D0'.

Currently **not implemented**: every experiment adapter (D1–D4), any
complementary DuckDB patch, any performance comparison, any Sluice change. The
absence is deliberate; see `docs/experiment-matrix.md`.

## Documentation

- [`docs/build-boundary.md`](docs/build-boundary.md) — build ownership,
  incremental-rebuild mechanics, profile isolation, evidence.
- [`docs/duckdb-stable-io-map.md`](docs/duckdb-stable-io-map.md) — v1.5.6
  synchronous and asynchronous I/O call chains with source references.
- [`docs/experiment-matrix.md`](docs/experiment-matrix.md) — arms and admission.
- [`docs/r0-report.md`](docs/r0-report.md) — R0 result, environment, limitations.

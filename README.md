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
- `--depth 1` clones carry no tags, so `git describe` in such a checkout fails
  even though the commit is right. Verify the pin by SHA, or fetch the tag:

```bash
git submodule status                                   # both SHAs, authoritative
git -C third_party/duckdb fetch --tags --depth 1 origin
git -C third_party/duckdb describe --tags --exact-match  # only after the fetch
```

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
ctest --test-dir build/cmake -R duckdb.benchmark.smoke --output-on-failure   # slow label, TPC-H sf=1

# Everything (13 tests)
ctest --test-dir build/cmake --output-on-failure
```

`sluice-only` preset skips the DuckDB build (`cmake --preset sluice-only`).

## Development workflow (R0.1 gates)

Commits and PR titles follow [Conventional Commits](docs/development/commit-convention.md):
`<type>(<scope>): <subject>` with a required kebab-case scope (e.g.
`feat(adapter): add native filesystem wrapper`). Lefthook enforces the rule
locally; GitHub Actions checks the PR title plus the checker self-test
(**Repository Policy PASS** — a policy verdict, not a build verdict).

One-time setup after cloning:

```bash
# Install lefthook (a single static Go binary; no Node/npm involved):
go install github.com/evilmartians/lefthook/v2@v2.1.16
#   or: brew install lefthook
#   or download a release binary from https://github.com/evilmartians/lefthook/releases
lefthook install        # wires commit-msg / pre-commit / pre-push into .git/hooks
```

Fast local verification (what `pre-push` runs, sequentially, fail-fast):

```bash
bash tools/check-commit.sh --self-test                          # checker refutes itself
bash tools/push-range.sh validate                               # commits this push publishes (manual: current branch)
bash tools/push-range.sh whitespace                             # whitespace in those commits
bash tools/tests/push-range-test.sh                             # resolver scenarios (dev-run)
cmake --preset sluice-only && \
cmake --build build/cmake-sluice --parallel 4 && \
ctest --test-dir build/cmake-sluice --output-on-failure --parallel 1
```

The build+CTest step is triggered by the hook only when the push touches
build files, C++ sources, tests, benchmarks, tools, hooks or submodule
gitlinks; a docs-only push skips the compile but still runs the convention
and whitespace checks. The pushed refs come from Git's own pre-push stream
(the refs it will actually publish, including mirror and matching pushes), so
the gate never reconstructs them from the command line. A new remote ref is
validated against the immutable pre-policy boundary
(`6e5f5c6db08f5b6780e13d92f357c65cdc865538`, the R0 main tip): inherited R0
history is never re-judged, while new commits and unrelated roots still are.
Manual run (all hook commands; the compile step stays path-dependent, so a
skipped CTest is a skip, not a pass):

```bash
lefthook run pre-push --all-files
# complete gate, forcing build+CTest even for a docs-only range:
DUDUDU_FORCE_BUILD_GATE=1 lefthook run pre-push --all-files
```

Full local validation remains the author's responsibility and depends on the
change scope — see the verification table in
[`AGENTS.md`](AGENTS.md). DuckDB adapter/experiment changes additionally
require the DuckDB build, correctness tests and the benchmark oracle before
review; the lightweight CI will never produce that evidence.

## Sluice SDK

Sluice is built by **its own xmake project**, never by a second CMake definition:

```bash
# what cmake/Sluice.cmake does, per profile
cd build/sluice-work/noliburing
# --builddir is relative on purpose: xmake stores a relative value against the
# project dir but resolves it against the invocation CWD, so an absolute path
# lands the objects one directory deeper than intended.
xmake f -P ../../../third_party/sluice -m release --liburing=n -y --builddir=out
xmake -y sluice_core && xmake -y sluice_async
# staging is wiped first so it is always exactly this version's install set
cmake -E rm -rf ../../sluice-stage/noliburing
xmake install -o ../../sluice-stage/noliburing sluice_core
xmake install -o ../../sluice-stage/noliburing sluice_async
```

The SDK prefix is `build/sluice-sdk/{noliburing,liburing}` and holds exactly the
11 contracted headers plus `libsluice_core.a` and `libsluice_async.a`.
Consumers link in GNU order: `-lsluice_async -lsluice_core [-luring]`.

CMake exposes dududu-local imported targets `Sluice::core`, `Sluice::async`,
`Sluice::core_uring`, `Sluice::async_uring`. These are **not** an upstream CMake
package — Sluice exports none.

## DuckDB native benchmark smoke

DuckDB's runner selects benchmarks by a **positional name pattern**, not by a
flag. `--benchmark=...` does not exist: an unknown `--x=y` is parsed as a custom
*benchmark* argument, so the runner executes all 1033 registered benchmarks and
then aborts in whichever one validates that argument.

`--root-dir` is required in practice. The default root is the DuckDB source
tree, which is also the directory scanned for the `benchmark/` tree of
interpreted `.benchmark` files, so it cannot simply be pointed anywhere -- but
left at the default the runner writes ~200 MB of generated TPC-H data into
`third_party/duckdb`. Symlink the pinned `benchmark/` directory into a scratch
root and let all writes land there:

```bash
mkdir -p build/duckdb-bench
ln -sfn "$PWD/third_party/duckdb/benchmark" build/duckdb-bench/benchmark

# the DuckDB build tree is SHA-scoped: one directory per submodule HEAD
DUCKDB_SHA=$(git -C third_party/duckdb rev-parse HEAD)
./build/duckdb-native/$DUCKDB_SHA/benchmark/benchmark_runner --list | head
./build/duckdb-native/$DUCKDB_SHA/benchmark/benchmark_runner \
    'benchmark/tpch/parquet/parquet_projection_direct.benchmark' \
    --root-dir "$PWD/build/duckdb-bench" \
    --out="$PWD/build/duckdb-bench/out.txt"
```

Result correctness is **not** in the exit code: a `result` mismatch prints
`INCORRECT` to the `--out` stream and still exits 0. Read the output.
`tests/cmake/RunDuckdbBenchmarkSmoke.cmake` does exactly this.

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
- [`docs/development/commit-convention.md`](docs/development/commit-convention.md) —
  commit/PR title convention and the local verification gates.
- [`docs/r0-report.md`](docs/r0-report.md) — R0 result, environment, limitations.

# R0 report — Sluice × DuckDB experimental foundation

Status: **R0 complete.** This is infrastructure evidence, not a performance result.
No arm has been admitted, and no timing number in this document carries a
performance claim.

## 1. What R0 had to establish, and what it found

| Requirement | Result |
|---|---|
| Both submodules pinned to a full SHA, identities verified independently | PASS |
| Sluice built by its own xmake, installed as an SDK | PASS |
| External CMake consumer uses only the installed SDK | PASS |
| liburing support verified with a real ring, and honestly absent without it | PASS |
| Incremental rebuild + relink after a source edit | PASS (three-phase probe) |
| no cross-profile cache reuse | PASS (separate work dirs, `nm -u` counts 0 vs 11) |
| DuckDB stable release built by its own CMake, sources unmodified | PASS |
| At least one official unittest and one official benchmark actually execute | PASS |
| Sync and async I/O call chains traced in v1.5.6 sources | PASS (`docs/duckdb-stable-io-map.md`) |
| Five-arm structure recorded with admission boundaries | PASS (`docs/experiment-matrix.md`) |
| Any upstream production source modified | NONE |

Everything below is the evidence for that table.

## 2. Pinned identities

| Item | Value | How it was established |
|---|---|---|
| `SLUICE_TRACK` | `origin/master` | fetched `origin`, then checked out the branch head |
| `SLUICE_SHA` | `8fdcd99c5f9a42dadfe5aa0c095bf96c756aeb01` | `git -C third_party/sluice rev-parse HEAD`, branch reported as `master` |
| `DUCKDB_TRACK` | latest stable release | GitHub `releases/latest`, prerelease flag `false` |
| `DUCKDB_TAG` | `v1.5.6` | `git -C third_party/duckdb describe --tags --exact-match` |
| `DUCKDB_SHA` | `069cc9f9b5be802405797faecc284961b07c70ef` | resolved from the tag ref, not from the release page's `target_commitish` |

The DuckDB SHA was taken from `refs/tags/v1.5.6` after fetching that ref
explicitly. The release page also lists `069cc9f9...` as `target_commitish`, but
a release field is metadata; the tag ref is the thing git actually checked out,
so the tag resolution is what is recorded.

`git submodule status` at the R0 head reports both gitlinks at the SHAs above,
and `.gitmodules` pins them as gitlinks — a floating branch is never an
experiment identity.

## 3. Environment

| Field | Value |
|---|---|
| `BUILD_HOST` | WSL2 Ubuntu 26.04 LTS, kernel `6.18.54.1-microsoft-standard-WSL2` |
| `COMPILER` | g++ (Ubuntu 15.2.0-16ubuntu1) 15.2.0 |
| `CMAKE` | 4.2.3 |
| `NINJA` | 1.13.2 |
| `XMAKE` | v3.1.2+HEAD.5d21e9d |
| `LIBURING` | 2.14-1 (`liburing2` + `liburing-dev`) |
| `CXX_FLAGS` | `-O3 -DNDEBUG` (Release), DuckDB adds its own upstream flags |
| `CPU` | AMD Ryzen 7 5800H, 8 logical cores (`nproc` = 8) |
| `FILESYSTEM` | ext2/ext3 (WSL2 virtual disk) |
| `BUILD_PROFILE` | `release`, Sluice profiles `liburing=n` and `liburing=y` |

Platform claim is **Linux only**. Nothing here was verified on Windows or macOS,
and this report makes no statement about them.

## 4. Sluice SDK bridge

Mechanism and rationale are in `docs/build-boundary.md`; the evidence:

- Two ExternalProjects, one per profile, each with its own xmake work directory,
  staging directory and SDK prefix. `xmake f -P third_party/sluice -m release
  --liburing=<n|y> -y --builddir=out` runs with `CWD=<work>`, because xmake
  writes `.xmake` into the invocation directory. The builddir is relative on
  purpose: xmake stores a relative value against the project dir but resolves
  the stored value against the invocation CWD, so an absolute path put the
  objects in `build/build/sluice-work/<profile>/out` (found in review, fixed).
  Objects now sit at `build/sluice-work/<profile>/out/.objs`, 11 per profile.
  Verified: after a full build, `git -C third_party/sluice status --porcelain`
  is empty and `.xmake` exists only under `build/sluice-work/<profile>/`. The one exception is
  `compile_commands.json`, which Sluice's own `xmake.lua` regenerates in the
  project root via `plugin.compile_commands.autoupdate` and its own `.gitignore`
  ignores; see `docs/build-boundary.md`.
- Install is the two-call form the upstream verifier uses
  (`xmake install -o <stage> sluice_core` then `... sluice_async`).
- The SDK prefix holds exactly 11 headers + 2 archives per profile:

```
include/sluice/{effect,error,file_resource,measurement,result}.hpp
include/sluice/blocking/file.hpp
include/sluice/async/{async_io_context,request,request_scope,threadpool_backend,uring_backend}.hpp
lib/libsluice_core.a   (24K)
lib/libsluice_async.a  (204K without liburing, 276K with)
```

- `tests/cmake/VerifySdkBoundary.cmake` fails on any additional header, any
  `detail/` header, or a third archive. Consumers link through imported targets
  whose include directory *is* the prefix, so "no private headers" is structural.
- Link order follows the GNU static rule: `-lsluice_async -lsluice_core`, with
  `-luring` appended for the liburing flavor via the imported target's
  `INTERFACE_LINK_LIBRARIES`.
- `Sluice::*` are dududu-owned imported targets. They are not presented as a
  Sluice-exported CMake package, because Sluice does not export one.

Consumers (all built against the prefix only):

| Test | Proves |
|---|---|
| `sluice.sdk.core` | core file read/write round-trip, short read handling |
| `sluice.sdk.async.threadpool` | `RequestScope` bounded pipeline + `wait_for` + `take` |
| `sluice.sdk.async.uring` | real io_uring round-trip; exit 2 would mean NOT_SUPPORTED |
| `sluice.sdk.async.uring-absence` | on the `liburing=n` prefix, ring creation must return `not_supported` |
| `sluice.sdk.header-boundary` | installed surface is exactly the contracted set |

`sluice.sdk.async.uring` exited 0 here, so this host genuinely has a working
ring. The absence contract is proven separately against the `liburing=n` prefix,
so neither profile is inferred from the other.

## 5. DuckDB native baseline

Built from the unmodified pinned submodule with upstream options only:
`-DCMAKE_BUILD_TYPE=Release -DBUILD_SHELL=ON -DBUILD_UNITTESTS=ON
-DBUILD_BENCHMARKS=ON -DBUILD_EXTENSIONS=tpch -DCMAKE_POLICY_VERSION_MINIMUM=3.5`.

`CMAKE_POLICY_VERSION_MINIMUM=3.5` only restores the floor DuckDB's own
`cmake_minimum_required(VERSION 3.5...3.29)` declares; CMake 4.x rejects the
3.5 form otherwise. No source and no semantics change.

Products: `build/duckdb-native/duckdb` (54M), `test/unittest` (62M),
`benchmark/benchmark_runner` (54M). `duckdb --version` → `v1.5.6 (Variegata) 069cc9f9`.

Entry points proven by CTest:

| Test | What actually ran |
|---|---|
| `duckdb.shell.smoke` | `SELECT 42`; `COPY ... TO parquet` of 10 000 rows; `SELECT COUNT(*)` = 10000 |
| `duckdb.unittest.smoke` | `test/sql/select/test_select_empty_table.test` → `All tests passed (1 assertion in 1 test case)` |
| `duckdb.benchmark.list` | `--list` returns 1033 benchmark names |
| `duckdb.benchmark.smoke` | one TPC-H parquet benchmark, 5 measured runs, upstream `result` oracle satisfied |

## 6. Two traps in the DuckDB benchmark harness (found and handled)

Both are properties of the pinned source, and both would silently produce fake
evidence if ignored.

**Selection is positional, not a flag.** `benchmark_runner '<name_pattern>'`
selects benchmarks by regex over name and group. There is no `--benchmark=`.
Passing `--benchmark=X` is parsed as a *custom benchmark argument*, so the runner
runs every registered benchmark and then aborts inside whichever benchmark
validates that argument. Observed: a 16-minute run of all 1033 benchmarks that
produced no output file.

**The exit code does not encode result correctness.** `run_benchmarks` returns a
`ConfigurationError`, and `main` exits 1 only for "benchmark not found" or
"info without name". A benchmark whose `result` statement does not match logs
`INCORRECT` into the `--out` stream **and exits 0**. The correctness check must
read the output stream.

So `tests/cmake/RunDuckdbBenchmarkSmoke.cmake` rejects `INCORRECT`, `ERROR` and
`TIMEOUT` in the output and requires at least one numeric timing line. Negative
probe: a copy of the benchmark with a falsified `result` value
(`999999999999.0` instead of `226829357828.867781`) made the script exit non-zero
with `benchmark result did not match the upstream oracle`. The harness is an
oracle, not a rubber stamp.

**Generated data location.** The runner's default root is the DuckDB source
tree, which is where interpreted `.benchmark` files are discovered
(`<root>/benchmark`) and where generated dbgen/parquet/db files land. Running it
naively wrote ~200 MB into `third_party/duckdb` during R0; this was cleaned up and
`git -C third_party/duckdb status --porcelain --ignored` is empty. The script now
requires `ROOT_DIR` inside the ignored build tree and symlinks the pinned
source's `benchmark/` directory into it, so discovery still works while every
written byte stays in `build/duckdb-bench/`. Symlinking (not copying) avoids a
second vendor tree.

## 7. Stable-release I/O investigation

`docs/duckdb-stable-io-map.md` traces the actual v1.5.6 chains with file and line
references. Summary of what it establishes:

- **Sync chain**: SQL → `PhysicalTableScan` → `MultiFileFunction::MultiFileScan`
  → `ParquetReader::Scan` → `ThriftFileTransport::read` → `CachingFileHandle::Read`
  → `FileHandle::Read` → `FileSystem::Read` → `LocalFileSystem::Read` → `pread`.
  Reads are positional exact-N-or-throw: a short read cannot be expressed through
  this interface, EOF is an exception, and ownership stays with the buffer passed in.
- **Hidden I/O** that any adapter must account for: the external file cache
  (`enable_external_file_cache` defaults to `true`), Parquet read-ahead
  prefetching, the Parquet metadata cache, and the OS page cache.
- **Async chain**: `AsyncTask::Execute()` is synchronous `void`;
  `AsyncResultsExecutionMode::TASK_EXECUTOR` is the default for
  `PhysicalTableScanExecutionStrategy::DEFAULT`. A blocked scan returns
  `AsyncResultType::BLOCKED` and is retried by the executor.
- **Admission, preliminary**: Sluice Direct is `HOST_ADMISSION_CANDIDATE`
  (registration via `VirtualFileSystem::RegisterSubSystem` / `DBConfig::file_system`,
  no DuckDB patch). Sluice ThreadPool and io_uring true async are
  `REQUIRES_HOST_CHANGE`, because the host protocol fires the interrupt callback
  on task return, has no pending state for an outstanding request, and offers no
  way to yield a worker while an external completion is outstanding. Occupying a
  DuckDB worker with a blocking `wait_one()` is explicitly not accepted as async.
- The v2.0-dev chain from the #556 analysis (`ScanReadAhead`,
  `ReadAheadIOTask`, `ReadAheadJobCompletion`) does not exist in v1.5.6; nothing
  in this report is inferred from that branch.

## 8. Five-arm structure

`docs/experiment-matrix.md` defines D0 / D1 / D2 / D3 / D4 plus the control arm
D0' that is required if the host scheduler is ever modified. R0 created the
directories with status READMEs and no placeholder sources: an empty directory
that says "not implemented" is honest, a stub that compiles and does nothing is
not.

## 9. Not implemented, unresolved, or unverified

- **No arm exists yet.** D1–D4 are R1/R2. There is no adapter, no wrapper, no
  Sluice-backed FileSystem.
- `build/duckdb-native/` now accumulates one directory per DuckDB SHA the
  checkout has ever built (~170 MB each). They are ignored, deletable, and kept
  by default so the binary behind a recorded result stays identifiable.
- **No performance number is claimed.** The benchmark smoke is entry-point
  evidence with a correctness oracle attached. Five timings of one TPC-H parquet
  query on one machine are not a result.
- **D3/D4 remain unproven**: whether true completion-driven async is expressible
  without a host change is a preliminary judgement backed by source reading, not
  by a working prototype. Only a host-refactor prototype can settle it.
- **TPC-H SF100 not attempted** in R0, by design.
- **Cross-platform**: unverified outside Linux/WSL2.
- **WSL2 virtiofs/interop** was not tuned; `FILESYSTEM` is reported because file
  system choice affects any later I/O measurement, not because R0 measured it.

## 10. Reproduce from a clean checkout

```bash
git clone <repo> dududu && cd dududu
git submodule update --init --recursive --depth 1
git submodule status                     # must show 8fdcd99c... and 069cc9f9...

cmake --preset release                   # or: cmake -S . -B build/cmake -G Ninja
cmake --build build/cmake                # Sluice SDK (both profiles) + DuckDB native
ctest --test-dir build/cmake --output-on-failure
```

Measured on a fresh clone of this branch: `cmake --build build/cmake -j8`
completed in 12m32s, and `ctest` reported 9/9 passed in 5.8s afterwards
(`duckdb.benchmark.smoke` 5.64s once the TPC-H sf=1 parquet already exists).
Both submodules reported no tracked or untracked changes after the run.

Sluice-only loop (fast, no DuckDB build):

```bash
cmake --preset sluice-only
cmake --build build/cmake-sluice
ctest --test-dir build/cmake-sluice --output-on-failure
```

The manual xmake path, byte-for-byte equivalent to what CMake drives, is listed
in `README.md`.

## 11. Known rough edges

- The SDK sync step deliberately re-runs `xmake` on every build so that source
  edits are detected; that keeps the first build slow and every later build
  honest. A build that skipped xmake entirely would be faster and would silently
  miss edits.
- `build/duckdb-bench/` accumulates ~200 MB of generated TPC-H data. It is
  inside the ignored build tree and can be deleted freely.
- `cmake -P` returns non-zero on `message(FATAL_ERROR)`, so a failed check in a
  CTest script really does fail the test. This was verified explicitly rather
  than assumed, because every DuckDB smoke test depends on it.

## 12. Review record

Review passes A and B were run against the original R0 head; B2 (the PR #1
re-review) against the same code, independently. Findings were fixed in
follow-up commits rather than argued away.

### Review A — build correctness

| Check | Result |
|---|---|
| Submodule SHAs and release identity | PASS — `git submodule status` on a fresh clone gives `8fdcd99c...` and `069cc9f9...`; `ls-remote` confirms both are the pinned refs, and the release API confirms `v1.5.6` is `Latest`, not a prerelease |
| xmake / CMake responsibility split | PASS — CMake owns orchestration and imported targets; `xmake.lua` owns compilation; no Sluice source is listed in any CMakeLists |
| No private headers in the SDK | PASS — installed surface equals the 11 entries of upstream's `EXPECTED_V2_HEADERS` exactly, and the four headers in upstream's `DELETED_HEADERS` (`cancel`, `fiber`, `fiber_ctx`, `stackful_io_host`) are absent from the tree and the prefix |
| Static link order and dependencies | PASS — link lines read `libsluice_async.a libsluice_core.a -luring`; `ldd` shows `liburing.so.2` for the uring consumer and none for the core consumer |
| `liburing` never silently stubbed | PASS — configure logs `checking for liburing capability ... ok`, and every failure branch in `xmake/uring.lua` raises |
| Edit triggers recompile and relink | PASS — see the four-phase table in `docs/build-boundary.md` |
| No cross-profile cache reuse | PASS — separate `.xmake` per profile, 11 objects each, `nm -u` io_uring symbol counts 0 vs 11 |
| Clean checkout reproduces the README | PASS — fresh clone, `--depth 1` submodules, `cmake --preset release`, full build 12m32s, 9/9 tests |

Findings raised and fixed:

- **F1** — an absolute `--builddir` was resolved against the project dir when
  stored but against the invocation CWD when used, so objects landed in
  `build/build/sluice-work/<profile>/out` while the docs said `<work>/out`.
  Fixed by passing the relative value `out`.
- **F2** — the report claimed `git status --porcelain --ignored` was empty in the
  Sluice submodule. Sluice's own `xmake.lua` regenerates `compile_commands.json`
  there and its own `.gitignore` ignores it, so the claim was false. Narrowed to
  "no tracked or untracked changes" and documented.
- **F3** — the documented pin verification used `git describe`, which cannot work
  in the `--depth 1` checkout the README tells people to create. The README now
  verifies by SHA and offers the tag fetch as an optional extra.

### Review B — experimental validity

| Check | Result |
|---|---|
| DuckDB Native unmodified | PASS — `git -C third_party/duckdb status --porcelain` empty before and after the full build and all tests |
| Real official stable release | PASS — tag ref resolved, release metadata agrees |
| Runners executed, not merely built | PASS — shell returns query results, unittest prints `All tests passed (1 assertion in 1 test case)`, benchmark emits 5 timings and satisfies its `result` clause |
| I/O DAG matches this release | PASS — every reference spot-checked against v1.5.6 sources: `AsyncExecutionTask::ExecuteTask` (`async_result.cpp`), the `BLOCKED` branch (`physical_table_scan.cpp`), `FileSystem::Read` exact-count-or-throw (`file_system.hpp`), the `pread` loop with EOF-as-exception (`local_file_system.cpp`), `enable_external_file_cache` default `true` (`settings.hpp`), `ReadAheadBuffer` over a `CachingFileHandle` (`thrift_tools.hpp`) |
| Arms can separate wrapper tax, host tax and Sluice cost | PASS — D1 is the wrapper control, D2 isolates Sluice on an unmodified host, D0' is the host-refactor control that makes D3/D4 attributable |
| Build smoke not used as performance evidence | PASS — no timing from the benchmark smoke appears as a result anywhere; the report says so explicitly |
| Synchronous waits not labelled async | PASS — D3/D4 are `REQUIRES_HOST_CHANGE`, and blocking `wait_one()` in a DuckDB worker is called out as unacceptable |
| Unverifiable capabilities marked, not guessed | PASS — `NOT_YET_DETERMINED` is used only where a prototype is genuinely required to settle the question |

No blocking findings. The two documentation claims that were wrong are the F2
and F3 items above, both corrected.

### Review B2 — second independent pass (PR #1 re-review)

Verdict was **REVISE**: two P1 findings against build trustworthiness, two P2s,
one non-blocking note. All fixed in this branch; each P1 was first turned into
a failing regression test on the unfixed tree, then fixed, then green.

| Finding | Verdict then | Fix and proof |
|---|---|---|
| **P1** — a DuckDB submodule update kept the previous release running: the external build is stamp-driven with no dependency on submodule content (`UPDATE_COMMAND ""`, `BUILD_ALWAYS FALSE`) | reproduced on the real bridge (source identity A→B, `cmake --build`, binary still A) | binary dir, ExternalProject prefix and exported `DUDUDU_DUCKDB_SHA` bound to the submodule HEAD SHA; `CMAKE_CONFIGURE_DEPENDS` watches the submodule's `HEAD`/loose ref/`packed-refs` so the next `cmake --build` re-runs CMake and builds fresh into the new SHA's directory. `duckdb.build.sha-refresh` drives the real `cmake/DuckDB.cmake` against a stub git source: red before the fix, green after, both move shapes (branch commit, detached HEAD) |
| **P1-2** — the Sluice staging tree was never cleaned, so a header dropped by a future Sluice would survive in staging and ride SyncSdk's copy into the SDK, past the prefix-side prune | confirmed by reading the chain (stage glob → copy → prune only sees stage-absent files) | install step wipes staging before `xmake install`; `sluice.sdk.install-wipe` plants a rogue file in the real staging tree and proves it vanishes from stage and SDK (red before the fix); `sluice.sdk.stale-sync` pins the sync contract hermetically: shrink removes, unchanged keeps mtime, changed updates |
| **P2** — `CMakePresets.json` did not pin a generator | confirmed | `"generator": "Ninja"` on the base preset |
| **P2** — the header-boundary check ran only on the `noliburing` prefix | confirmed | now runs on both profiles (`sluice.sdk.header-boundary.noliburing`, renamed from `sluice.sdk.header-boundary`, and `sluice.sdk.header-boundary.liburing`); neither profile is inferred from the other |
| non-blocking — `release` and `sluice-only` share `DUDUDU_BUILD_ROOT` | confirmed | documented as serialize-or-isolate in `docs/build-boundary.md`; no code change while builds stay serial |

The negative-proof test suite lives in `tests/cmake/` and is registered under
the "Build-mechanics negative proofs" block: these tests replay the bridge
mechanisms against fixtures (and, for the install wipe, against the real xmake
chain) so the failure mode shows up as a red CTest rather than as silently
invalidated evidence. The suite is now 13 tests; the full matrix was re-run
green after the fixes, including the DuckDB entry points against a fresh
SHA-scoped build of the pinned v1.5.6 source.

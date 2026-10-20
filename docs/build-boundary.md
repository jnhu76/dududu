# Build boundary

Who owns what, and how the three build systems meet without overlapping.

## Ownership

| Layer | Owner | Authority |
|---|---|---|
| Sluice library + its xmake build + installed header allowlist | `third_party/sluice` (pinned submodule) | Sluice `docs/explicit-io-contract.md`, `xmake/*.lua`, `scripts/verify_v2_package.py` |
| DuckDB core semantics + its CMake build + official tests/benchmarks | `third_party/duckdb` (pinned submodule) | the checked-out release source itself |
| Experiment adapters, build composition, consumers, benchmarks, evidence | `dududu` (this repo) | this repo's `docs/`, `AGENTS.md` |

dududu does **not**:

- re-declare Sluice sources in CMake (no second build definition),
- patch, fork, or vendor either upstream's source,
- provide a Python build/experiment orchestrator,
- introduce Bazel/Meson/Conan/vcpkg.

## Task graph

```
cmake --build build/cmake --target sluice_core_consumer
   └── ExternalProject sluice_sdk_noliburing
         configure: xmake f -P third_party/sluice -m release --liburing=n
                    --builddir=<work>/out        (CWD = <work>, so .xmake lands there)
         build:     xmake -y sluice_core && xmake -y sluice_async
         install:   rm -rf <stage>                                 (staging is wiped first)
                    xmake install -o <stage> sluice_core
                    xmake install -o <stage> sluice_async      (two calls, verified form)
         sdk_sync:  SyncSdk.cmake  <stage> -> build/sluice-sdk/noliburing
   └── imported targets Sluice::core, Sluice::async (+ *_uring variants)
   └── link consumer with -I<sdk>/include -L<sdk>/lib -lsluice_async -lsluice_core [-luring]

cmake --build build/cmake --target duckdb_native
   └── ExternalProject duckdb_native
         upstream CMake + Ninja, unmodified source, upstream options only
```

Directories (all under the ignored `build/`):

```
build/
├── sluice-work/{noliburing,liburing}/     .xmake cache + out/.objs (per profile)
├── sluice-stage/{noliburing,liburing}/    raw xmake install output (wiped before each install)
├── sluice-sdk/{noliburing,liburing}/      the SDK prefix consumers actually use
├── cmake/                                 CMake/Ninja build tree for dududu
├── duckdb-native/<duckdb-sha>/            upstream DuckDB build tree, one per submodule SHA
├── duckdb-bench/                          benchmark root (linked benchmark/, generated data)
└── ep/                                    ExternalProject stamps and logs (duckdb/<sha> per generation)
```

The `release` and `sluice-only` presets configure two CMake trees that share one
`DUDUDU_BUILD_ROOT`. They must be driven **serially**: both would run `xmake`
in the same work directories and both would drive the same DuckDB build tree,
and neither build system holds a lock against the other. Give a second tree its
own `-DDUDUDU_BUILD_ROOT` if two builds must run in parallel.

## Why each isolation rule exists

**xmake cache placement.** `xmake` writes its per-project configuration into the
*invocation* working directory, not into `-P <project>`. The build therefore runs
with `CWD=build/sluice-work/<profile>` and `-P <submodule>`; `.xmake` and all
objects (`--builddir`) stay in the ignored work directory. Verified: after a
configure+build, `git -C third_party/sluice status --porcelain` is empty and no
build product appears under the submodule's `src/` or `include/`.

One artifact does still land inside the submodule: `compile_commands.json`.
Sluice's own `xmake.lua` opts into
`add_rules("plugin.compile_commands.autoupdate")`, xmake writes that file to the
project root, and Sluice's own `.gitignore` lists it. dududu can relocate or
suppress it only by modifying the submodule, which is not allowed, so it is
documented rather than hidden. It is ignored, untracked, and no commit, build
input, or experiment identity depends on it — but the accurate claim is "no
tracked or untracked content changes", not "the submodule sees no writes".

**`--builddir` is relative on purpose.** xmake stores a relative `--builddir`
against the *project* dir but resolves the stored value against the *invocation*
CWD when it builds. Pass an absolute path and those two disagree: with
`--builddir=<work>/out` the objects landed in
`build/build/sluice-work/<profile>/out`, one directory deeper than documented
(observed during R0 and fixed). `--builddir=out` resolves once, against the work
dir that is already the CWD, so objects sit at
`build/sluice-work/<profile>/out/.objs/...` and nowhere else.

**Two work directories, two profiles.** `--liburing=n` and `--liburing=y` must
never share a `.xmake` cache. Sluice's `xmake/uring.lua` documents the failure
mode it defends against (a profile switch silently reusing the other profile's
objects); separate work directories make that impossible at the dududu level as
well.

**Staging plus `copy_if_different`.** `xmake install` rewrites files
unconditionally and never prunes. The install step therefore wipes the staging
tree before xmake runs, so staging is always exactly the current version's
install set. `SyncSdk.cmake` copies only changed bytes — an unchanged SDK keeps
its mtime, so an unchanged build does not relink consumers — and removes prefix
files the fresh install no longer produces. Without the wipe, anything left in
staging by an older Sluice would ride the copy into the SDK, past the
prefix-side prune (found in review B2). Proven by `sluice.sdk.stale-sync` (the
sync contract, hermetic) and `sluice.sdk.install-wipe` (a file planted in the
real staging tree cannot reach the SDK).

**`sdk_sync` as a `BYPRODUCTS` step.** The SDK archives are outputs of a named
ExternalProject step. Without a declared producer, Ninja evaluates a consumer's
link edge before the install runs, treats the stale archive as up to date, and a
genuinely changed archive never causes a relink. This was observed and fixed
during R0 (see below).

**`LINK_DEPENDS` on consumers.** CMake places IMPORTED libraries on the link line
as implicit prerequisites of the *target*, but the archive file itself is not a
build-graph input the way a compiled object is; naming the archives in
`LINK_DEPENDS` is what makes "archive changed → consumer relinks" hold. Also
observed and fixed during R0.

## Incremental behaviour (verified)

Three-phase probe in an isolated `git worktree` of the Sluice submodule, with a
separate build root (`build/` untouched, submodule untouched):

| Phase | Archive SHA-256 (first 16) | Object mtime | Consumer binary mtime |
|---|---|---|---|
| first build | `331a95ebc7feffda` | (built) | 10:30:05.100253505 |
| rebuild, no changes | `331a95ebc7feffda` | unchanged | 10:30:05.100253505 (not relinked) |
| after a one-line source edit | `bc877fe95152e5fb` | 10:30:08.456294863 | 10:30:10.105921019 (relinked) |
| rebuild, no changes again | `bc877fe95152e5fb` | 10:30:08.456294863 | 10:30:10.105921019 |

The object mtime column is the load-bearing one: an unchanged archive could in
principle come from a full recompile that happens to be byte-identical, so "no
relink" alone does not prove "no recompile". The object timestamp shows a
no-change build recompiles nothing, while the edited build produces a new object,
a different archive, and a relinked consumer.

The no-change build still re-enters `xmake` (that is what lets xmake detect
source edits) and still runs the sync step, but no object, archive or binary
changes.

Reproduce (destructive only inside `/tmp`, never inside the submodule):

```bash
git -C third_party/sluice worktree prune
git -C third_party/sluice worktree add --detach /tmp/probe-src HEAD
cmake -S . -B /tmp/probe-build -G Ninja \
      -DDUDUDU_SLUICE_SOURCE_DIR=/tmp/probe-src \
      -DDUDUDU_BUILD_ROOT=/tmp/probe-root \
      -DDUDUDU_BUILD_DUCKDB_NATIVE=OFF
cmake --build /tmp/probe-build --target sluice_core_consumer
sha256sum /tmp/probe-root/sluice-sdk/noliburing/lib/libsluice_core.a
stat -c %y /tmp/probe-build/tests/sluice_core_consumer
cmake --build /tmp/probe-build --target sluice_core_consumer   # must not change either
stat -c %y /tmp/probe-root/sluice-work/noliburing/out/.objs/sluice_core/linux/x86_64/release/src/blocking_file.cpp.o
printf '\nnamespace sluice { int probe_marker() { return 42; } }\n' >> /tmp/probe-src/src/blocking_file.cpp
cmake --build /tmp/probe-build --target sluice_core_consumer   # new archive, relinked binary
```

`git worktree prune` is required before re-running: the previous probe's
worktree is removed with the `/tmp` directory, but the registration is not.

## Profile isolation (verified)

| Profile | `.xmake` location | Installed files | io_uring refs in `libsluice_async.a` |
|---|---|---|---|
| `liburing=n` | `build/sluice-work/noliburing/.xmake` | 11 headers + 2 archives | 0 |
| `liburing=y` | `build/sluice-work/liburing/.xmake` | 11 headers + 2 archives | 11 (`nm -u`) |

`liburing=y` resolved a real liburing (`/usr/include/liburing.h` +
`liburing.so`) during configure; the capability probe in `xmake/uring.lua` fails
the build rather than silently degrading to the stub. Nothing about the stub is
inferred: the absence profile is proven at runtime by
`sluice.sdk.async.uring-absence` (expects `not_supported`) and the presence
profile by `sluice.sdk.async.uring` (a real ring round-trip).

## SDK surface

Consumers see exactly the 11 contracted headers and 2 archives, on **both**
profiles. `tests/cmake/VerifySdkBoundary.cmake`
(`sluice.sdk.header-boundary.noliburing` and `sluice.sdk.header-boundary.liburing`)
fails the build on any extra header, any `detail/` header, or any third archive.
No consumer includes a path under `third_party/sluice/`; the clean-room property
is structural (the imported target's include directory is the prefix) rather than
a convention.

## DuckDB

Upstream CMake with upstream options only:

```
-DCMAKE_BUILD_TYPE=Release -DBUILD_SHELL=ON -DBUILD_UNITTESTS=ON
-DBUILD_BENCHMARKS=ON -DBUILD_EXTENSIONS=tpch
-DENABLE_SANITIZER=OFF -DENABLE_UBSAN=OFF
-DCMAKE_POLICY_VERSION_MINIMUM=3.5
```

`CMAKE_POLICY_VERSION_MINIMUM=3.5` restores the floor DuckDB's own
`cmake_minimum_required(VERSION 3.5...3.29)` declares, which the local CMake 4.x
otherwise rejects. It changes no source and no semantics.

**SHA-scoped build identity.** The external build is stamp-driven and has no
dependency on submodule content: with `UPDATE_COMMAND ""` and
`BUILD_ALWAYS FALSE`, updating the submodule left the previous release running
while every build looked green (reproduced in review B2 — source identity moved
A→B, the consumed binary still reported A; the same failure is described in the
CMake ExternalProject docs for a pre-existing `SOURCE_DIR`). The binary dir,
the ExternalProject prefix (stamps and logs) and the exported
`DUDUDU_DUCKDB_SHA` are therefore bound to the submodule's full HEAD SHA at
configure time, and the submodule's `HEAD`, loose ref and `packed-refs` are
registered in `CMAKE_CONFIGURE_DEPENDS`. The next `cmake --build` after a
gitlink move re-runs CMake, resolves the new SHA and builds from scratch into
the new SHA's directory — the old tree is never reused. Consumers resolve all
paths through the exported `DUDUDU_DUCKDB_BIN_DIR`; a literal path anywhere
would silently pin one generation. Previous-generation trees remain under
`build/duckdb-native/` (ignored, deletable) so the binary behind an already
recorded result stays identifiable. Proven by `duckdb.build.sha-refresh`, which
drives the real `cmake/DuckDB.cmake` against a stub git-repository source and
covers both move shapes (branch commit and detached HEAD).

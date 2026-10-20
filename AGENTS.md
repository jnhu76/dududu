# AGENTS.md — dududu working rules

dududu is an experiment harness. It owns composition and evidence, not upstream
semantics.

## Ownership

- **Sluice's specification is owned by `third_party/sluice`.** Its contract,
  conformance ledger, public headers and xmake build are authoritative there.
  dududu must not restate the contract or "fix" a consumer by reaching into
  `include/sluice/detail/` or `src/`.
- **DuckDB's semantics are owned by the pinned release source.** dududu must not
  patch it for an experiment without recording the patch as a host change and
  adding the D0' control arm.
- **dududu owns** experiment adapters, build composition, tests, benchmarks and
  performance evidence.

## Rules

1. **Every result carries both SHAs.** `DUDUDU_SHA`, `SLUICE_SHA`,
   `DUCKDB_TAG` + `DUCKDB_SHA`, plus build profile and SDK prefix identity.
2. **Correctness admission precedes any performance run.** A benchmark number
   from an arm that has not matched D0's result is not a result.
3. **Never fake true async.** A synchronous wait on a DuckDB worker
   (`wait_one()` in `AsyncTask::Execute()`, or any blocking adapter) is
   `REQUIRES_HOST_CHANGE`, not "async". Report it as such.
4. **Never modify or merge upstream automatically.** No commits, branches or PRs
   in `third_party/sluice` or `third_party/duckdb`. A candidate Sluice change
   lives in a separate branch/fork and is proposed to Sluice only after evidence
   exists.
5. **No `sleep` as synchronization in tests.** Use the happens-before edge the
   code under test provides; a sleep that makes a test pass is a broken test.
6. **Build products never enter Git.** `build/`, SDK prefixes, benchmark JSON,
   perf traces and datasets stay ignored.
7. **One concern per commit.** Repository bootstrap, SDK bridge, DuckDB baseline
   and experiment architecture are separate commits.
8. **No new toolchains without a real need.** Prefer Bash, Git, CMake, CTest and
   Lefthook; do not add Node/npm, Husky, commitlint, Docker or a new orchestrator
   for what these already cover.

## Reading order for a change

1. `docs/build-boundary.md` — who builds what, and why the edges exist.
2. `docs/duckdb-stable-io-map.md` — the actual v1.5.6 call chain. Do not reason
   from a newer DuckDB or from #556's v2.0-dev notes; those interfaces do not
   exist here.
3. `docs/experiment-matrix.md` — admission rules for the arm being touched.
4. `third_party/sluice/llms.txt` — navigation into Sluice's authority, not a
   substitute for it.

## Commits and pull requests

Every commit and every PR title follows the Conventional Commits dialect
defined in [`docs/development/commit-convention.md`](docs/development/commit-convention.md):

```text
<type>(<scope>): <subject>
```

with `type` ∈ `feat fix perf refactor test build ci docs chore revert`, a
required kebab-case scope naming a real responsibility (`repo`, `sdk`,
`cmake`, `duckdb`, `adapter`, `bench`, `oracle` — never phase labels like
`r0`/`d2`/`phase-1`), and a lowercase subject; header ≤ 72 characters, no
trailing full stop. One concern per commit (rule 7 above) and a semantic
header per commit.

Lefthook enforces this locally (`commit-msg`, `pre-commit`, `pre-push` — run
`lefthook install` once after cloning). Do not bypass with `--no-verify`;
fix the header instead. The pre-push gate never rewrites history and never
writes to the index or worktree. CI (`.github/workflows/repo-policy.yml`)
checks the PR title and runs the checker self-test — nothing else. Its
**Repository Policy PASS** is a policy verdict, never a build or correctness
verdict. Never report it as `BUILD_PASS` or `CORRECTNESS_PASS`.

## Verification before review

Local-first: hooks are bypassable and CI is policy-only, so the PR author —
human or coding agent — owns the correctness evidence. Before opening a PR
for review, run the verification that matches the change scope and record the
actual commands and results in the PR description:

| Change touches | Minimum local evidence |
| --- | --- |
| Docs only (`*.md`, docs/) | `lefthook run pre-push --all-files` (convention checks; the compile gate is skipped for real doc-only pushes) |
| CMake, SDK bridge, tools, hooks, CI, submodule pins | Sluice-only gate: `cmake --preset sluice-only && cmake --build build/cmake-sluice --parallel 4 && ctest --test-dir build/cmake-sluice --output-on-failure --parallel 1` |
| DuckDB adapter, experiment interfaces, correctness tests, benchmark oracle | The Sluice-only gate **plus** the DuckDB native build, DuckDB correctness tests (`ctest -R duckdb`), and the benchmark oracle, per `docs/experiment-matrix.md` admission. Performance numbers require the formal experiment admission; nothing here fakes it. |

PR descriptions must state what actually ran and what actually passed. A test
that was not run is not green, and a hook result may not be described as a
build result. Tests never use `sleep` as synchronization (rule 5). Within one
gate invocation the CTest run is serial (`--parallel 1` plus `RUN_SERIAL` on
the staging-mutating `sluice.sdk.install-wipe` test), so shared SDK staging
is never mutated concurrently by the gate itself; two independent builds or
CTest runs against the same checkout are outside the hook's control and
should not be run at the same time.

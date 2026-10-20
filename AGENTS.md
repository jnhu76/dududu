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

## Reading order for a change

1. `docs/build-boundary.md` — who builds what, and why the edges exist.
2. `docs/duckdb-stable-io-map.md` — the actual v1.5.6 call chain. Do not reason
   from a newer DuckDB or from #556's v2.0-dev notes; those interfaces do not
   exist here.
3. `docs/experiment-matrix.md` — admission rules for the arm being touched.
4. `third_party/sluice/llms.txt` — navigation into Sluice's authority, not a
   substitute for it.

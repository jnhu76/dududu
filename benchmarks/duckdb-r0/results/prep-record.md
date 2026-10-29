# DuckDB R0 prep receipts — E5 (2026-10-29)

Preparation evidence for the R0 closure protocol in this directory. Every line
below was executed on the E5 host during prep; none of it is a timing result.
Reproduce via the commands in `../README.md`.

## Identities

- DUDUDU branch `sluice-r0-closure` from `origin/main` =
  `b94041d918672d113ea0ca667ba8ccdabf329c80`.
- DUCKDB pin `069cc9f9b5be802405797faecc284961b07c70ef` (= remote
  `refs/tags/v1.5.6`, `git ls-remote` this host); submodule porcelain clean.
- Build: upstream options only, GCC 16.2.1, CMake 4.3.0, Ninja 1.13.2,
  `build/duckdb-native/069cc9f9…/`. `duckdb --version` prints
  `v0.0.1 (Unknown Version) 069cc9f9` — depth-1 checkout without the tag
  object (network blocked the fetch); the SHA is the identity.

## Entry points [RUN]

`ctest --test-dir build/cmake -R duckdb --output-on-failure` → 5/5 passed
(`duckdb.shell.smoke`, `duckdb.unittest.smoke`, `duckdb.benchmark.list`,
`duckdb.benchmark.smoke` with the upstream result oracle,
`duckdb.build.sha-refresh`). Both submodules porcelain-clean after the run.

## Dataset [RUN]

`build/duckdb-bench/duckdb_benchmark_data/lineitem.parquet`, 207 130 013 bytes,
SHA-256 `b7583e65198aaa9522067fd849f9d08f2668df2e7608fef548ab386cab0ef911`.

Regeneration determinism [RUN]: CLI `dbgen(sf=1, suffix='_regen')` + `COPY` to a
scratch file produced the identical SHA-256; scratch deleted afterwards.

## SQL oracle — stable output hashes [RUN]

Two full runs of `../oracle.sql` (run1, run2), identical per query:

| Query | SHA-256 |
|---|---|
| q1 | `54adfd2036d70b5566b591068599d4fd4e14deab0ab59fce000ac73b32258dca` |
| q2 | `6b7830ddc1bba06406e183ecf9938b005bac1deac33556bc18f49af3037c9189` |
| q3 | `673ce9f44c8f998b30b70c993bebfaf2cd7c68723c2c61c07b23807a6896d1c6` |
| q4 | `26788f24487c49629265bf0e227ebbeeb0d2a87f0a59ecd7639cea4b3a75b41e` |

q1 row count 6 001 215 and the q2 returnflag/linestatus groups match the
canonical TPC-H sf=1 values; the benchmark smoke's independent `result` oracle
passed in the same session.

## I/O exposure probe [RUN] — counts and sizes only, no timing

Warm single-process CLI run of the direct aggregate
(`SUM(l_extendedprice * (1 - l_discount) * (1 + l_tax))` over the dataset),
`strace -f -y -e trace=pread64`:

- 492 `pread64` calls against `lineitem.parquet`, 37 172 128 bytes returned,
  **0 short returns** (the exact-count contract is visible at the seam).
- Size spectrum: 147 × 256 B and a tail of 46–68 B (metadata/footer traffic);
  62 KB-class reads (55 × 61 935, 32 × 61 937, …); several ~634 KB reads.
- Cold-vs-warm comparison and per-column attribution: measurement-lane work
  (commands in `../README.md`); traces retained under the ignored
  `build/duckdb-bench/oracle-out/` on the E5 host.

## NOT_RUN_WITH_REASON

- Native A/A noise pairs: serial measurement lane, per the workflow's single
  benchmark lane. No timing was taken in prep.
- Cold-cache observation (`drop_caches`): needs root beyond the prep-scoped
  sudo (tool installation only); requires an explicit owner decision.
- DuckDB tag-object fetch and the `v1.5.6` display string: network refused the
  fetch during prep; identity rests on the SHA + remote tag ref above.

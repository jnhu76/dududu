# duckdb-request-geometry

Request-geometry study of the `pread(2)` stream DuckDB v1.5.6 issues while
scanning `lineitem.parquet` (mission Phase 6.2, Sluice #578 R1 input).

- `analyze_pread_geometry.py` — reproducible analyzer; attributes every trace
  request to the metadata-resolution step that triggered it (total
  classification; unattributed requests abort the run) and computes the
  adjacency/overlap/contiguity/coalescing statistics.
- `DUCKDB_METADATA_REQUEST_GEOMETRY.md` — the findings: request attribution,
  dependency tiers, and the one legal coalescing window (per-row-group
  projected-chunk span; measured 492 → 50 preads with the in-tree
  `prefetch_all_parquet_files` mechanism).
- `DUCKDB_METADATA_OPPORTUNITY_GATE.md` — the Phase 6.3/6.4 verdict: executed
  cost model, mechanism screening M0–M5, correctness oracle, bounded
  wall-clock probes and the five gate criteria →
  `NO_MATERIAL_OPPORTUNITY`; the formal A/B was not run, by the gate's own
  rule.
- `SLUICE_AC_RECOMMENDATIONS.md` — what this workload does and does not
  recommend for Sluice AC-1/2/3 and the True Async host change, plus the
  admission conditions for any next-stage product or Host API work.
- `results/trace-index.md` — provenance of the R0 strace inputs (paths,
  SHA-256, capture commands). Derived CSV/JSON outputs are regenerable and
  kept out of Git per dududu rule 6.

Uses the frozen R0 identities: DuckDB submodule `069cc9f9` (v1.5.6),
dataset SHA-256 `b7583e65…` (see the geometry doc for the full chain).

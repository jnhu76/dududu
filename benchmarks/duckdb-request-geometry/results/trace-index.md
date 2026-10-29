# Trace provenance index — duckdb-request-geometry

All inputs identified at analysis time (2026-10-29). Raw traces are R0 lane
recordings in the Sluice research tree; they never enter dududu Git (rule 6).
If a hash below matches, the analyzer output in the geometry doc reproduces
from it.

## Raw traces (Sluice tree, untracked there)

Base: `/home/jnhu/Source/Sluice/research/direct-beyond-parity/closure/r5-native/duckdb/`
(capture method: `research/direct-beyond-parity/closure/r5-native/03-duckdb-io-exposure.md`;
receipts: `benchmarks/duckdb-r0/results/lane-record.md` on dududu main)

| file | sha256 | content |
|---|---|---|
| `io-trace-warm.txt` | `067918177e207a2b668e643a57f451a772b5c62ac3774e28d10261345e7ab5cf` | 3-column aggregate query, warm cache (primary subject) |
| `io-trace-cold.txt` | `740db46c1c525dae5d2534cc6c4fd8fb8bebbdb4cc6e3f712844fa5a4715f5e0` | same query after drop_caches |
| `io-trace-1col-price.txt` | `a1c926244de88e7213cf7c3bade9af75b02d365e35b03ef4f1fc0d97bd6b5906` | `SUM(l_extendedprice)` only |
| `io-trace-1col-discount.txt` | `b4a263e165fd8b4811d5610af62294a7496a6ab495fd1d3a6ffb0dad5d6779f7` | `SUM(l_discount)` only |
| `io-trace-kstack.txt` | `96453f0ba2c5a207bd9988365a960e0758f063da48cfb781b1ccb62770b35c0c` | `strace -k` seam symbolization (R0) |

## Dataset and chunk table

| item | value |
|---|---|
| `lineitem.parquet` | 207,130,013 B, sha256 `b7583e65198aaa9522067fd849f9d08f2668df2e7608fef548ab386cab0ef911` — equal to the hash in `benchmarks/duckdb-r0/results/prep-record.md` |
| chunk table TSV | sha256 `446a1fe7c2ead22aec599690cf86d3c9c18ef432804b1d937ffa1e64005845ef`; regenerate: `duckdb -noheader -list -c "SELECT row_group_id, column_id, dictionary_page_offset, data_page_offset, total_compressed_size FROM parquet_metadata('duckdb_benchmark_data/lineitem.parquet') ORDER BY row_group_id, column_id;" > rg-chunks.tsv` (784 rows = 49 rg × 16 cols; DuckDB CLI `build/duckdb-native/069cc9f9…/duckdb`) |

## Traces recorded for this study (in `/tmp` at analysis time; regenerate with)

| file | sha256 | command |
|---|---|---|
| `geo-st-1thr.txt` | `1fa8d8902a94eda80d4caff7855423f62419a5288d42b52bbbfab72aaeac7f57` | default stream, single-threaded: `strace -f -y -e trace=pread64 -o geo-st-1thr.txt <duckdb> -noheader -list -c "SET threads=1; SELECT SUM(l_extendedprice*(1-l_discount)*(1+l_tax)) FROM read_parquet('duckdb_benchmark_data/lineitem.parquet');"` — reproduces the default 492-read pattern exactly |
| `geo-st-pf.txt` | `1a7ce3e09e46fa17bb9fdb120bb4a5c28448b07319934eb60b3d482612b24c86` | merged-span run: same + `SET prefetch_all_parquet_files=true;` — 50 preads = 49 exact projected-chunk spans + 1×262,144 B footer window |

## Analyzer outputs (derived, regenerable, not committed)

`results/{warm,cold,1col-price,1col-discount}-requests.csv` and
`results/*-geometry.json` — regenerate with `analyze_pread_geometry.py`
(commands in `DUCKDB_METADATA_REQUEST_GEOMETRY.md` §8).

## Classification cross-check (warm, analyzer)

492 = 1 footer_tail_probe + 1 footer + 147 page_header_window + 98
dict_page_data + 98 cache_interleave_piece + 147 page_body; 0 unclassified,
0 short reads, 0 repeated extents. Cold run: identical population. 1col
traces: price 100 = 2+49×2, discount 198 = 2+49×4 (matches lane-record
per-column attribution exactly).

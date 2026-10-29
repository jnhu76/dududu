# DuckDB Metadata Micro-Read — Request Geometry (R1, mission Phase 6.2)

Analysis of the real `pread(2)` request stream that DuckDB v1.5.6 issues while
scanning `lineitem.parquet`, answering the Phase 6.2 questions: fd/file
identity, offset/length/order, adjacency, overlap, repeated extents,
contiguity, the metadata-resolution step that triggers each request, when the
next request address becomes knowable, data dependencies, concurrent
modification, buffer/result ownership, and which consecutive requests form a
**legal** coalescing or prefetch window.

Nothing here infers batchability from request count or size. Every coalescing
claim below is backed by (a) measured contiguity, (b) the point in the reader
at which the next address is computable, and (c) an executed run of the
coalesced form on this host.

Analysis date: 2026-10-29. Branch: `r1-request-geometry` @ `dududu` merged main
`12a8712eb5ff5f48e570b49b1e01ad5821837dca` (R0, PR #7). DuckDB: submodule
`069cc9f9b5be802405797faecc284961b07c70ef` = tag `v1.5.6`, unmodified build
`build/duckdb-native/069cc9f9…/`. Dataset: `lineitem.parquet`, 207,130,013 B,
SHA-256 `b7583e65…` — identical to the hash recorded in
`benchmarks/duckdb-r0/results/prep-record.md`.

## 1. Inputs and method

Raw strace captures are the R0 lane's own recordings (not re-measured):
`research/direct-beyond-parity/closure/r5-native/duckdb/io-trace-{warm,cold,
1col-price,1col-discount,kstack}.txt` in the Sluice tree. Provenance (paths,
SHA-256, capture commands): `results/trace-index.md`.

The analyzer `analyze_pread_geometry.py` parses the trace (pairing strace
`unfinished`/`resumed` line splits FIFO per tid), selects preads on the
dataset, and attributes **every** request to one of six trigger classes by
joining against the Parquet column-chunk table (`parquet_metadata()` over the
same file, exported to TSV). Classification is total: an unattributable
request aborts the run. All counts below are analyzer output over the warm
trace; the cold trace produces the identical request population (§4).

Verification against the R0 record (`benchmarks/duckdb-r0/results/lane-record.md`):

| Metric | R0 recorded | Analyzer (warm) | Analyzer (cold) |
|---|---|---|---|
| preads on `lineitem.parquet` | 492 | 492 | 492 |
| bytes returned | 37,172,128 | 37,172,128 | 37,172,128 |
| calls ≤ 4 KiB | 344 (48,674 B) | 344 (48,674 B) | 344 (48,674 B) |
| short reads | 0 | 0 | 0 |
| `SUM(l_extendedprice)` alone | 100 / 31,086,130 B | 100 / 31,086,130 B | — |
| `SUM(l_discount)` alone | 198 / 3,123,007 B | 198 / 3,123,007 B | — |

## 2. fd / file identity

21 fds on the same file per query (warm = cold): fd 3 on the main thread
(60541) for open-time footer reads, and 20 scan fds (4–23), one per scan
thread — 28–31 `openat`s were recorded in R0, 20 threads carry the scan. All
`O_RDONLY`. Each scan fd's stream is private to its thread; there is no fd
sharing across scan threads.

The row-group → fd assignment is **scheduler-dependent**: warm and cold runs
issue the identical request multiset (§4) but assign row groups to different
threads (e.g. warm fd 10 reads row groups {6, 22, 41}; cold fd 10 reads
{6, 26}). 9 fds take 3 row groups, 11 take 2 (49 = 9×3 + 11×2).

## 3. What triggers each request — total attribution

File layout: 49 row groups × 16 columns; the query projects columns 5
(`l_extendedprice`, no dictionary), 6 (`l_discount`) and 7 (`l_tax`), both
dictionary-encoded. Chunk k of a row group starts exactly where chunk k−1
ends (verified for all 49 row groups by the analyzer, §6). Per projected
chunk, chunk span = [min(dictionary_page_offset, data_page_offset),
+ total_compressed_size).

| # | class | count | bytes | trigger (v1.5.6 code path) |
|---|---|---|---|---|
| 1 | `footer_tail_probe` | 1 | 8 | `LoadMetadata` reads the last 8 B for the `PAR1` magic + 4-B footer length; local files take `prefetch_size = 8` because `ShouldAndCanPrefetch` is false for on-disk files (`parquet_reader.cpp:48-56,103-110`) |
| 2 | `footer` | 1 | 79,613 | footer (Thrift `FileMetaData`) read; yields schema and, for every chunk of every row group, its start offset and `total_compressed_size` |
| 3 | `page_header_window` | 147 | 37,632 | `ColumnReader::PrepareRead` fetches a 256-B window (`ASSUMED_HEADER_SIZE`) before each page-header parse and parses it from that buffer (`column_reader.cpp:276-287`) |
| 4 | `dict_page_data` | 98 | 4,831 | dictionary-page payload (`compressed_page_size` of the `DICTIONARY_PAGE`, 46–68 B here) read by `PreparePage` → `ReadData` (`column_reader.cpp:307-315,401-430`) |
| 5 | `cache_interleave_piece` | 98 | 6,203 | the data-page-header 256-B window (`[data_page_offset, +256)`) overlaps the still-cached dict-header window `[chunk_start, +256)`; `CachingFileHandle::Read` copies the overlap and reads only the remainder `[chunk_start+256, +256+…)` as one pread (`caching_file_system.cpp:141-192`, `ReadAndCopyInterleaved` :444+) |
| 6 | `page_body` | 147 | 37,043,841 | compressed page payload (`compressed_page_size` from the parsed header) read by `PreparePage` → `ReadData` |

147 = 49 × 3 (one header window per projected chunk), 98 = 49 × 2 (dict
columns only). Class 5 is the R0 "mystery" third micro-read of dictionary
chunks: for `l_discount` rg0 it is `pread(68 @ chunk_start+256)` where
68 = data_page_offset − chunk_start = the part of the second 256-B window not
already covered by the first window's cached range; it is an emergent
artifact of the database-level external file cache (enabled by default,
`enable_external_file_cache = true`, `settings.hpp:731-737`), not a Parquet
structure. Thrift body reads bypass that cache entirely
(`thrift_tools.hpp:153-156`), which is why body reads are full-length single
preads.

Micro-read budget: classes 1+3+4+5 = 344 calls ≤ 4 KiB moving 48,674 B —
69.9% of calls, 0.131% of bytes, exactly the R0 numbers — and every one of
them is a metadata-structure fetch (page-header windows, dictionary payloads,
cache-interleave remainders), not data.

## 4. Order, adjacency, overlap, repetition, contiguity

Per-fd issue order (analyzer, warm): 20 scan fds × 20–30 requests. Within one
fd one row group is a fixed 10-read batch (plain chunk: header window + body;
each dict chunk: header window + dict payload + interleave piece + body), and
the three projected chunks of a row group are processed together.

- **Exact contiguity**: body_end == next chunk header start for every
  within-row-group chunk boundary (6 per 3-row-group fd). Row-group spans
  themselves are contiguous: for all 49 row groups the three projected chunks
  form one file range with zero holes (analyzer `row_group_span_contiguous_all
  = true`).
- **Backward overlap**: 15 of 29 transitions per 30-request fd are
  self-overlaps: each body read re-reads the tail of its own 256-B header
  window (body starts 14–111 B into the window). Total redundant bytes per
  row group ≈ 540 B.
- **Gaps**: the only large gaps are row-group switches (≈ 2.4 MB median on
  this file; min observed inter-read gap is 14 B). No gap exists between
  projected chunks of the same row group.
- **Repeated extents**: zero — no (offset, length) pair repeats anywhere in a
  query.
- **Cold vs warm**: the request *population* is identical — same 492
  (offset, length, ret) triples, same (row group, class) multiset, same
  totals — but the fd carrying each row group differs. The page cache changes
  latency and thread assignment, not what is requested.

Cross-fd: the 20 scan streams are disjoint in file space (disjoint row-group
spans, shared footer only), so no cross-thread range is ever requested twice.

## 5. Dependency structure — when is the next address knowable?

Three tiers, from the reader source:

- **T0 — open time, before any data read.** After the footer parse, the start
  and `total_compressed_size` of every projected chunk of every row group are
  known. The projected three-chunk span of a row group is therefore a fully
  determined contiguous file range at open time. DuckDB itself computes
  exactly this range when prefetching is enabled
  (`ColumnReader::RegisterPrefetch`, `column_reader.cpp:129-134`, merged by
  `ReadAheadBuffer` with a 16 KiB gap tolerance, `thrift_tools.hpp:39-101`).
- **T1 — after a 256-B header-window parse.** The length of a page body
  (`compressed_page_size`) and, for dict chunks, the dictionary payload
  length exist only inside the parsed header. This is a true data dependency:
  in default mode the body pread address/length is not computable before the
  header window has been fetched and parsed. The dependency costs a syscall
  round trip per page in default mode; under merged prefetch the header
  window is served from the already-fetched buffer (`thrift_tools.hpp:137-147`)
  and the dependency costs only a CPU parse.
- **T2 — never knowable in advance.** Cache-interleave piece boundaries
  (emergent from cache state), and the inter-thread interleaving of streams
  (scheduler).

Concurrency: scan threads are independent (private fds, disjoint ranges);
they share the database-level external file cache under a lock
(`caching_file_system.cpp:122-139`). File modification: POSIX gives an
O_RDONLY reader no immutability guarantee; DuckDB detects external
modification via version tag / mtime and drops cached ranges
(`caching_file_system.cpp:125-135`). The R0 dataset is pinned by SHA-256 and
never written during a query; any coalescing/prefetch layer implicitly
assumes this query-local stability, which the experiment satisfies by
construction.

Buffer / result ownership: page bodies are read directly into scan-state
buffers (`ResizeableBuffer` `block` / `compressed_buffer`) through the
`LocalFileSystem::Read(FileHandle&, void*, off_t, len)` seam; header windows
live in `ReadAheadBuffer` head buffers (BufferManager, `EXTERNAL_FILE_CACHE`
tag) freed by `ClearPrefetch` (`column_reader.cpp:286`). Return semantics are
exact-count: 0 short reads across all 1,282 observed preads (492×2 + 100 +
198). Any adapter must preserve the "read exactly len at offset into my
buffer" contract or hand back a buffer it owns plus a copy.

## 6. Legal coalescing windows

**W1 — per-row-group projected-chunk span (legal, and already implemented
upstream).** For every row group, the union of what the default stream reads
is exactly the contiguous span [first projected chunk start, last chunk end]:
verified for all 49 spans, zero holes, zero over-read. All addresses are
known at T0 from the footer DuckDB already parses; page headers, dict
payloads and bodies are all inside the span, so the T1 dependency is
satisfied by parsing from the buffer instead of by separate syscalls.

This is not a proposal — it is an existing v1.5.6 mechanism gated off for
local files (`ShouldAndCanPrefetch` requires `prefetch_all_parquet_files`
for on-disk files, `parquet_reader.cpp:48-56,1447-1509`). Measured on this
host, single-threaded, same query, same binary, `SET
prefetch_all_parquet_files=true`:

| | default stream | merged-span run | delta |
|---|---|---|---|
| preads on the dataset | 492 | **50** | −442 (−89.8%) |
| bytes returned | 37,172,128 | 37,315,569 | +143,441 (+0.39%) |
| reads ≤ 4 KiB | 344 | 0 | −344 |
| footer reads | 2 (8 B + 79,613 B) | 1 (262,144 B window) | +182,523 B over-read |
| data-span reads | 490 | 49 × exact span, 37,053,425 B | zero extra bytes |

The 49 span reads match the projected-span table byte-for-byte (analyzer
cross-check); the entire over-read is the one-time footer prefetch window
(clamped to the last 256 KiB of the file). Planner cost is ~zero: chunk
offsets/sizes come from metadata the reader already parses, and the merge
machinery is the reader's own.

**W2 — within-chunk header+body pairs: NOT legally batchable as-is.** The
body address/length is header-parse-dependent (true T1 dependency), and the
pairs overlap (body re-reads the window tail), so no syscall-level merge
covers them; W1 is the legal route around them. The only contiguous,
non-overlapping, both-addresses-known consecutive pairs in the stream are
body_end → next chunk header — subsumed by W1.

**W3 — cross-row-group / cross-thread: no window.** Row-group spans are
~2.4 MB apart in file space (the 16 KiB `ALLOW_GAP` merge tolerance correctly
refuses them) and disjoint across threads.

**`preadv` (M2) applicability: none.** `preadv` scatters one contiguous file
range into discrete caller buffers; the default stream's adjacent pairs
overlap or have gaps, and under W1 a single span is consumed by one reader
state machine, not by discrete buffers. Synthesizing `preadv` over
non-contiguous offsets would be illegal.

## 7. Input to the Phase 6.4 opportunity gate (no verdict claimed here)

Quantified, measured physical-work delta of the one legal window (W1):
−442 syscalls and −344 micro-structure fetches per single-file query seam,
+143,441 B (+0.39%) bytes, in exchange for larger resident prefetch buffers.
Query-level wall-clock benefit is **not measured here** — that is the
Phase 6.3/6.3 arms' job (M1/M3 with the R0 A/A noise regime as reference:
paired A/B at n=15 resolves ≈ ±3–5% on the W1b workload, ≈ ±1% on W2). For
scale: 442 avoided preads at warm-page-cache costs (sub-2 µs each) estimate
to roughly 0.1–1 ms against a 35.9 ms W1b mean — i.e. plausibly below the
W1b resolution and worth spending W2-grade resolution on before any adapter
work. If the wall-clock delta cannot clear the recorded noise floor, the
honest verdict is `NO_MATERIAL_OPPORTUNITY` for latency even though the
syscall-count reduction itself is real, reproducible and free of extra bytes.

## 8. Reproduction

```bash
# chunk table (projected columns selected by the analyzer)
duckdb -noheader -list -c "SELECT row_group_id, column_id, dictionary_page_offset, \
  data_page_offset, total_compressed_size FROM parquet_metadata('<lineitem.parquet>') \
  ORDER BY row_group_id, column_id;" > rg-chunks.tsv

# classify an R0 trace
python3 analyze_pread_geometry.py --trace io-trace-warm.txt --label warm \
  --chunks rg-chunks.tsv --dataset <lineitem.parquet> --out-dir results/

# reproduce the merged-span run (single-threaded)
strace -f -y -e trace=pread64 -o pf.txt \
  build/duckdb-native/069cc9f9…/duckdb -noheader -list -c \
  "SET threads=1; SET prefetch_all_parquet_files=true; \
   SELECT SUM(l_extendedprice*(1-l_discount)*(1+l_tax)) \
   FROM read_parquet('duckdb_benchmark_data/lineitem.parquet');"
```

Analyzer exit is non-zero on any unattributed request. Full provenance:
`results/trace-index.md`; run log: `logs/geometry.md`.

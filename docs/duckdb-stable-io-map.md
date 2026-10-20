# DuckDB v1.5.6 — stable I/O call-chain map

Read-only investigation of the pinned submodule. Every claim below is from the
checked-out source at:

```
DUCKDB_TAG = v1.5.6
DUCKDB_SHA = 069cc9f9b5be802405797faecc284961b07c70ef
```

**This is not the #556 v2.0-dev chain.** `ScanReadAhead`, `ReadAheadIOTask`,
`ReadAheadJobCompletion` and the `TaskExecutor` integration those notes describe
do not exist in v1.5.6. The only `ReadAhead` symbols here are parquet's
synchronous `ReadAheadBuffer` over a byte buffer (`extension/parquet/include/thrift_tools.hpp:58`).
The v1.5.6 protocol is `AsyncResult`/`AsyncTask` (§3), which is a different
mechanism with different guarantees.

Paths below are relative to `third_party/duckdb/`.

---

## 1. Synchronous read path

### 1.1 DAG

```
SQL query
 └─ PhysicalTableScan::GetDataInternal
    src/execution/operator/scan/physical_table_scan.cpp:159
    (strategy from debug_physical_table_scan_execution_strategy, default DEFAULT -> TASK_EXECUTOR)
      └─ MultiFileFunction<ParquetMultiFileInfo>::MultiFileScan
         src/include/duckdb/common/multi_file/multi_file_function.hpp:601
           └─ data.reader->Scan(context, gstate, lstate, chunk)
              multi_file_function.hpp:621
                └─ ParquetReader::Scan(GlobalTableFunctionState&, LocalTableFunctionState&, DataChunk&)
                   extension/parquet/parquet_multi_file_info.cpp:728
                     └─ ParquetReader::Scan(ParquetReaderScanState&, DataChunk&)
                        extension/parquet/parquet_reader.cpp:1401
                          └─ ColumnReader / ThriftFileTransport::read
                             extension/parquet/include/thrift_tools.hpp:132 (read)
                               ├─ ReadAheadBuffer::Prefetch  (thrift_tools.hpp:114)
                               │    └─ CachingFileHandle::Read  (thrift_tools.hpp:119)
                               └─ FileHandle::Read(context, buf, len, location)  (thrift_tools.hpp:155,
                                  the non-prefetch fallback; bypasses the external cache)
                                    └─ CachingFileHandle::Read(data_ptr_t&, nr_bytes, location)
                                       src/storage/caching_file_system.cpp:141
                                       (cache hit -> BufferHandle, no syscall; cache miss -> line 149)
                                         └─ FileHandle::Read(QueryContext, void*, int64_t, idx_t)
                                            src/include/duckdb/common/file_system.hpp:86-87
                                              └─ FileSystem::Read(FileHandle&, void*, int64_t, idx_t)
                                                 src/include/duckdb/common/file_system.hpp:156
                                                   └─ LocalFileSystem::Read
                                                      src/common/local_file_system.cpp:484
                                                        └─ pread(2)  (local_file_system.cpp:490)
```

### 1.2 File opening and routing

- `ParquetReader::ParquetReader` builds a `CachingFileSystem` and opens the file
  through it: `fs(CachingFileSystem::Get(context_p))`, then
  `file_handle = fs.OpenFile(context_p, file, FILE_FLAGS_READ)`
  (`extension/parquet/parquet_reader.cpp:870-875`). A non-seekable handle is
  rejected (`NotImplementedException`), so FIFOs/streams never reach the reader.
- `CachingFileSystem::Get` is `CachingFileSystem(FileSystem::GetFileSystem(context), *context.db)`
  (`src/storage/caching_file_system.cpp:68-70`) — the caching layer *wraps* the
  database's filesystem rather than replacing it.
- `FileSystem::GetFileSystem(context)` (`src/include/duckdb/common/file_system.hpp:144`)
  resolves to the `DBConfig::file_system` instance
  (`src/include/duckdb/main/config.hpp:194`).
- `VirtualFileSystem::OpenFile` picks a sub-system by path
  (`src/common/virtual_file_system.cpp:146`), and sub-systems are added through
  `FileSystemRegistry::RegisterSubSystem`
  (`src/common/virtual_file_system.cpp:41-52`). Compressed files go through a
  separate registry (`RegisterSubSystem(FileCompressionType, ...)`), and a
  `CachingFileSystemWrapper` is inserted whenever the open flags request caching
  (`virtual_file_system.cpp:152-159`).

Consequence for an adapter: **a custom `FileSystem` can be installed without
patching DuckDB** (register a sub-system, or replace `DBConfig::file_system`
before/at startup). But it sits *under* `CachingFileSystem` and *under*
`CachingFileSystemWrapper`, so it does not see reads that those layers serve from
their buffers.

### 1.3 Read semantics (the contract a Sluice adapter must satisfy)

| Property | Behaviour in v1.5.6 | Source |
|---|---|---|
| Positional read | `Read(handle, buffer, nr_bytes, location)` must deliver **exactly** `nr_bytes` | `file_system.hpp:156` comment ("Read exactly nr_bytes … Fails if nr_bytes could not be read") |
| Short read | Not representable positionally. `LocalFileSystem::Read(at)` loops on `pread`; `pread == 0` before the requested count is exhausted throws `IOException` ("Could not read enough bytes") | `src/common/local_file_system.cpp:488-503` |
| EOF | Only expressible as the exception above (positional) or as a short return from the sequential form `Read(handle, buffer, nr_bytes)` (`read(2)`, `local_file_system.cpp:508-521`) | same |
| Error | `pread == -1` → `IOException` carrying `errno`; no partial-progress result type | `local_file_system.cpp:491-494` |
| Offset | Explicit `location` for the positional form; the sequential form keeps `current_pos` on the handle | `local_file_system.cpp:484,508` |
| Ownership | `FileHandle` owns the fd, is created by `OpenFile`, lives in `CachingFileHandle::file_handle` (`unique_ptr`), and is destroyed with the reader/scan state | `caching_file_system.hpp:31-95`, `parquet_reader.cpp:875` |
| Retry | None at this layer; `EINTR` is not retried in `LocalFileSystem::Read` | `local_file_system.cpp:489-494` |

Sluice's `blocking::read_at` returns a byte count (short read is a value, not an
exception). An adapter therefore has to *compose* `read_exact` semantics on top,
or translate short reads into the DuckDB exception contract. This is a real
semantic gap, not a formality: `read_exact` changes the retry/loop behaviour on
short reads and on reaching EOF.

### 1.4 What hides I/O from any adapter

1. **External file cache.** `enable_external_file_cache` defaults to `true`
   (`src/include/duckdb/main/settings.hpp:731-739`). `CachingFileHandle::Read`
   returns a `BufferHandle` from the cache without touching the filesystem on a
   hit (`src/storage/caching_file_system.cpp:141-192`). A Sluice adapter placed at
   the `FileSystem` layer will see only misses.
2. **Parquet metadata/row-group prefetch.** `ReadAheadBuffer::Prefetch` reads
   contiguous spans through `CachingFileHandle` (`thrift_tools.hpp:114-125`);
   `ThriftFileTransport::read` falls back to a 1,000,000-byte prefetch
   (`thrift_tools.hpp:148-151`). This is **synchronous read-ahead on the calling
   thread**, not asynchronous I/O.
3. **Parquet file metadata cache.** `ParquetFileMetadataCache` keeps footer/
   metadata across queries (`extension/parquet/parquet_file_metadata_cache.cpp`),
   so a warm second query can skip the footer reads entirely.
4. **Buffer manager / OS page cache.** Unavoidable; R1 must control for it with a
   cold/warm protocol rather than assume the adapter saw every byte.

### 1.5 Minimal Sluice Direct integration point (D2)

- **Where:** a `FileSystem` subclass registered via `VirtualFileSystem::RegisterSubSystem`
  (or a `DBConfig::file_system` replacement) whose `Read(handle, buf, n, location)`
  issues `sluice::blocking::read_exact`-equivalent reads, plus `OpenFile`/`GetFileSize`/
  `CanSeek`/`Close`.
- **Change size:** one adapter translation unit plus a registration hook; **no
  DuckDB patch**. Expected surface: `FileSystem` + `FileHandle` overrides for
  open/read/size/seek/close, and an exact-read loop because `read_at` may return
  short.
- **What it does not capture:** cache hits (§1.4.1) and the synchronous prefetch
  pattern (§1.4.2) still run on the caller thread; D2 measures "DuckDB's existing
  synchronous pattern, with Sluice as the byte mover", not overlap.
- **Must also be measured:** D1 (a pass-through native wrapper with the same
  call structure) exists precisely to price the adapter layer itself, so D2's
  delta is attributed to Sluice and not to the wrapper.

---

## 2. Asynchronous path

### 2.1 The protocol that actually exists

`src/include/duckdb/parallel/async_result.hpp`:

- `class AsyncTask { virtual void Execute() = 0; }` (:27-31) — synchronous,
  `void`, no completion handle.
- `class AsyncResult` (:33-71) carries `AsyncResultType` plus
  `vector<unique_ptr<AsyncTask>>`; constructed from tasks it becomes `BLOCKED`.
- `AsyncResultsExecutionMode { SYNCHRONOUS, TASK_EXECUTOR }` (:22-25).
- `PhysicalTableScanExecutionStrategy::DEFAULT` maps to `TASK_EXECUTOR`
  (`src/parallel/async_result.cpp:184-193`), so `BLOCKED` is permitted by default
  for table scans.

### 2.2 Where an I/O task would be created, and who owns what

```
ParquetReader::Scan  (would return AsyncResult(BLOCKED, tasks))
  extension/parquet/parquet_multi_file_info.cpp:728
    ↳ MultiFileScan propagates BLOCKED when mode == TASK_EXECUTOR
      src/include/duckdb/common/multi_file/multi_file_function.hpp:623-637
      (in SYNCHRONOUS mode it instead calls res.ExecuteTasksSynchronously() and loops)
        ↳ PhysicalTableScan::GetDataInternal
          src/execution/operator/scan/physical_table_scan.cpp:186-195
          data.async_result.ScheduleTasks(input.interrupt_state, context.pipeline->executor);
          return SourceResultType::BLOCKED;
            ↳ AsyncResult::ScheduleTasks
              src/parallel/async_result.cpp:86-101
              one AsyncExecutionTask per AsyncTask, scheduled on the TaskScheduler
                ↳ AsyncExecutionTask::ExecuteTask
                  src/parallel/async_result.cpp:36-45
                  async_task->Execute();
                  if (--counter == 0) interrupt_state.Callback();
                    ↳ InterruptState::Callback
                      src/include/duckdb/parallel/interrupt.hpp:47-70
                      (TASK mode: wakes the blocked PipelineTask)
```

- **Who holds the file and the buffer:** the reader's scan state
  (`ParquetReaderScanState`) and the `CachingFileHandle`; buffers are
  `BufferHandle`/`ResizeableBuffer` owned by the column readers and the prefetch
  read heads.
- **How completion reaches the query executor:** only through
  `InterruptState::Callback()` after the counter reaches zero
  (`async_result.cpp:36-45`). There is no per-completion notification, no
  progress fd, and no resumption token beyond "the task woke up".
- **Worker waiting/yielding:** `PipelineTask::ExecuteTask` returns
  `TaskExecutionResult::TASK_BLOCKED` on `INTERRUPTED`
  (`src/parallel/pipeline.cpp:44-49`); the scheduler is free to run other work.
  But the *I/O itself* runs inside `AsyncTask::Execute()` on a worker thread.
- **Cancellation / error / drain / shutdown:** owned by DuckDB's existing
  `Executor`/`TaskScheduler`/`PipelineExecutor` machinery. `AsyncResult` has no
  cancel surface; a task cannot report failure except by throwing from
  `Execute()`, which surfaces through DuckDB's error manager.

### 2.3 What the host cannot currently express

`AsyncTask::Execute()` is `void` and the completion counter is decremented the
moment it returns (`async_result.cpp:37-41`). Therefore:

- A task that *submits* to Sluice and returns immediately would have the counter
  hit zero and `Callback()` fire **while the I/O is still in flight** — the
  pipeline would resume early and read uninitialised data. Incorrect.
- A task that blocks inside `Execute()` until the I/O completes is functionally
  correct but **occupies a DuckDB worker for the whole I/O latency** — precisely
  the "blocking `wait_one()` in a host worker" anti-pattern R0 forbids labelling
  as true async.
- There is no "pending, will complete later" task state, and no way for an
  external progress owner to resume the pipeline without going through the
  counter.

Also note: parquet's BLOCKED path is compiled only under
`DUCKDB_DEBUG_ASYNC_SINK_SOURCE` and produces sleep/throw test tasks
(`parquet_multi_file_info.cpp:728-736`). No production parquet scan in v1.5.6
returns `BLOCKED`.

### 2.4 Admission classification

| Arm | Backend | Classification | Source basis |
|---|---|---|---|
| D2 | Sluice Direct (completed-return) | **HOST_ADMISSION_CANDIDATE** | `FileSystem`/`FileHandle` are virtual and registrable (`file_system.hpp:144-156`, `virtual_file_system.cpp:41-52`); no host patch needed. Synchronous semantics only. |
| D3 | Sluice ThreadPool, true async | **REQUIRES_HOST_CHANGE** | `AsyncTask::Execute()` is synchronous `void`; completion is counted on return (`async_result.cpp:27-47`). No pending state, no external wake path. |
| D4 | Sluice io_uring, true async | **REQUIRES_HOST_CHANGE** | Same task-contract limit as D3, plus the notification-fd/progress-owner path (`poll_progress`, `progress_notification_fd`) has no integration point in `Executor`/`TaskScheduler`. |

`NOT_YET_DETERMINED` is not used for D3/D4: the blocking constraint is visible in
the task interface itself, not inferred from performance.

### 2.5 Smallest host change that would admit true async (R2 design, not implemented)

1. Give `AsyncTask` a tri-state completion contract, or add a second task kind
   that does **not** decrement the completion counter on return and instead
   completes through an explicit token.
2. Let a reader hand the executor a resumption token bound to
   `InterruptState` (`interrupt.hpp:47-70`) so an external progress owner can
   fire `Callback()` exactly once per accepted batch.
3. Drive `poll_progress()`/`wait_one()` from a single fixed owner that is **not**
   a DuckDB worker (the Sluice D4 contract requires one progress owner); the
   executor only receives "batch N is ready" and reschedules the pipeline.

Because this changes the host, the experiment matrix adds **D0' — Native
Host-Refactor Control**: the same DuckDB patch with the *native* filesystem, no
Sluice. Without D0' a D3/D4 delta is not attributable.

---

## 3. Open questions carried into R1

- Whether `ExternalFileCache` can be disabled per-query in a way that is
  acceptable for measurement (`enable_external_file_cache=false`) without
  changing adapter semantics.
- Whether the `CachingFileSystemWrapper` inserted for cached open flags double
  counts reads (two caching layers) on the parquet path.
- Exact accounting of parquet prefetch spans (`ReadAheadBuffer` merges read heads
  within `ALLOW_GAP`) so D2's "bytes Sluice served" is measured, not assumed.
- Whether `TASK_EXECUTOR_BUT_FORCE_SYNC_CHECKS` is usable as a correctness oracle
  for an adapter that returns `BLOCKED`.

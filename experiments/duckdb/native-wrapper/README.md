# D1 — Native FileSystem wrapper

Status: **R1. Not implemented.**

A pass-through `FileSystem`/`FileHandle` over the native syscall path, installed
with the same registration mechanism D2 will use, doing no Sluice work.

Purpose: price the adapter layer itself. Without D1, any D2 delta would mix
"Sluice" with "the cost of being a `FileSystem` subclass". D1 must be admitted
against D0 on correctness and measured on the identical workload before D2 runs.

Entry point under investigation: `VirtualFileSystem::RegisterSubSystem`
(`third_party/duckdb/src/common/virtual_file_system.cpp:41`), documented in
`docs/duckdb-stable-io-map.md` §1.2.

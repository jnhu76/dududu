#pragma once

// Request-trace capture and I/O-only replay.
//
// Capture runs a workload through a TracingBackend in an untimed diagnostic
// pass and records every ReadAt(offset, length) the Parquet reader issued.
// Replay re-executes the same request list through either backend, reading
// into a real buffer and consuming every returned byte through a checksum, so
// an arm cannot win by not moving bytes. Replay explains I/O cost only; it is
// never presented as a Parquet decode.

#include <cstdint>
#include <string>
#include <vector>

#include "dududu/parquet/io_backend.hpp"

namespace dududu::parquet {

struct TraceRequest {
    uint64_t index = 0;
    uint64_t offset = 0;
    uint64_t requested = 0;
    uint64_t returned = 0;
    bool ok = true;
};

struct TraceFile {
    std::string dataset_sha;
    std::string dataset_path; // where the dataset lived at capture time
    std::string workload;
    std::string arm;
    uint64_t file_size = 0;
    std::vector<TraceRequest> requests;
};

// JSON Lines: one header object, then one object per request. The reader is
// strict about the version line.
std::string serialize_trace(const TraceFile& trace);
bool parse_trace(std::string_view text, TraceFile* out);

// Untimed diagnostic capture of one workload run. verify=false: the workload
// runs normally but nothing here is a timing sample.
arrow::Status capture_trace_to_file(Arm arm, const std::string& workload_name,
                                    const std::string& parquet_path,
                                    const std::string& out_path);

struct ReplayOutcome {
    uint64_t fnv = 0xcbf29ce484222325ULL; // FNV-1a 64 over all returned bytes, in order
    uint64_t requests = 0;
    uint64_t bytes = 0;
    std::vector<std::string> mismatches;

    bool ok() const { return mismatches.empty(); }
};

// Replays `trace` through `backend` (already opened on the same file).
ReplayOutcome replay_trace(IoBackend& backend, const TraceFile& trace);

// open + replay + close convenience; fails the replay if open/close fail.
// The dataset path comes from the trace header. With verify_dataset (the
// default) the file is hashed first and must still match the captured
// dataset_sha; a timed caller that has already verified the identity once
// may pass false to keep the hashing out of the measured loop.
arrow::Result<ReplayOutcome> replay_trace_file(const std::string& backend_name,
                                               const TraceFile& trace,
                                               bool verify_dataset = true);

} // namespace dududu::parquet

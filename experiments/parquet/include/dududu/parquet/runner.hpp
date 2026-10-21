#pragma once

// Workload execution over the three arms with identical phase boundaries.
//
//   open_meta : builder open + (T1) metadata inspection / (T2,T3) reader build
//   read      : the actual ReadTable call (T2 projection / T3 full scan)
//   verify    : oracle digest, measured separately and never inside `read`
//
// The arm choice is the ONLY difference between two runs of the same
// workload: P0 uses arrow::io::ReadableFile, P1/P2 use the same AdapterFile
// over their backend. Every phase is bracketed identically for every arm.

#include <arrow/api.h>

#include <memory>
#include <string>
#include <vector>

#include "dududu/parquet/io_backend.hpp"
#include "dududu/parquet/oracle.hpp"

namespace parquet {
class FileMetaData;
}

namespace dududu::parquet {

enum class Workload { t1_meta, t2_projection, t3_full };

const char* workload_name(Workload wl);

// T2 reads these column indices (one numeric, one string); projection happens
// inside the Parquet reader, never by decoding everything and dropping.
const std::vector<int>& projection_columns();

struct RunOptions {
    bool verify = false; // compute the oracle digest (cost lands in verify_s)
};

struct RunPhases {
    double open_meta_s = 0.0;
    double read_s = 0.0;
    double verify_s = 0.0;
};

struct RunResult {
    int64_t rows = 0;
    int64_t decoded_cells = 0;
    int columns_read = 0;
    int row_groups = 0;
    RunPhases phases;
    IoCounters counters; // p1/p2 only; p0 has no transparent hook point
    OracleReport oracle; // when verify
    MetadataReport metadata; // when t1
};

arrow::Result<RunResult> run_workload(Arm arm, Workload wl, const std::string& path,
                                      const RunOptions& opts);

} // namespace dududu::parquet

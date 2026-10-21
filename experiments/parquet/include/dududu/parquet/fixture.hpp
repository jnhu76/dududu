#pragma once

// Deterministic Parquet fixture generation.
//
// Every cell is a pure function of (row, column-tag) through a splitmix64
// finalizer, so generation order, chunk layout and run order can never leak
// into the data. The schema deliberately mixes shapes so that a decoding bug
// cannot pass unnoticed: sequential and shuffled integers, two null ratios,
// two string-length regimes (including empty strings), booleans with nulls,
// and alternating row-group sizes for varied column-chunk lengths.

#include <arrow/api.h>

#include <cstdint>
#include <string>
#include <vector>

namespace dududu::parquet {

struct FixtureSpec {
    const char* name;
    int64_t rows;
    std::vector<int64_t> group_sizes; // alternating; must sum to rows
};

// "small" (fast tests) and "medium" (benchmark scan) are frozen experiment
// parameters; their on-disk SHA-256 is recorded in the run manifest and in
// benchmarks/parquet/protocol.md.
const FixtureSpec* find_fixture_spec(const std::string& name);

// Column layout shared by generator and oracle (indices are experiment
// parameters: T2 projects {1, 4}).
//   0 id          int64    sequential 0..rows-1, non-null
//   1 shuffle     int64    non-monotonic, non-null
//   2 i32_null10  int32    ~10% nulls
//   3 f64_null5   double   ~5% nulls
//   4 text        utf8     length 0..24
//   5 wide        utf8     length 0..192
//   6 flag_null25 boolean  ~25% nulls
int num_fixture_columns();

// Builds the full table in memory.
arrow::Result<std::shared_ptr<arrow::Table>> build_fixture_table(const FixtureSpec& spec);

// Writes the table with one row group per spec entry. `compression` is
// "none" or "snappy"; an unavailable codec is an error, never a silent fall
// back to uncompressed.
arrow::Status write_fixture_parquet(const arrow::Table& table, const FixtureSpec& spec,
                                    const std::string& compression, const std::string& path);

struct GeneratedFixture {
    std::string path;
    std::string sha256;
    int64_t bytes = 0;
};

// Generates (or regenerates, byte-identically for one Arrow writer
// version — the manifest records it) `<out_dir>/<name>.parquet`.
arrow::Result<GeneratedFixture> generate_fixture(const std::string& name,
                                                 const std::string& out_dir,
                                                 const std::string& compression);

} // namespace dududu::parquet

#pragma once

// Correctness oracle: a canonical, run-stable digest of everything a Parquet
// read produced.
//
// Rules (frozen):
//   * schema part — per field: name ':' arrow type ToString() ':' nullable,
//     joined with ';'.
//   * data part — SHA-256 over a canonical byte stream:
//       - row count as ASCII decimal + '\n'
//       - per column, in table order: field name + '\n', then per chunk, per
//         row one record:
//           null      -> "N\n"
//           boolean   -> "0\n" | "1\n"
//           integer   -> "i" + signed decimal + "\n"
//           float     -> IEEE-754 bit pattern, 16 lowercase hex digits + "\n"
//                        (NaN canonicalizes to 0000000000000000)
//           string    -> base16 length ":" base16 bytes "\n"
//   * No std::hash, no pointers, no object layout: everything is derived from
//     logical values and names only.
//
// The digest is what P0 == P1 == P2 is asserted on, and what the corruption,
// truncation and fake-backend negative controls must move.

#include <arrow/api.h>

#include <cstdint>
#include <string>
#include <vector>

namespace parquet {
class FileMetaData;
}

namespace dududu::parquet {

struct OracleReport {
    std::string schema_sha;   // schema digest alone
    std::string data_sha;     // value digest alone (row count included)
    int64_t rows = 0;
    int64_t decoded_cells = 0; // logical values seen, nulls included
    std::vector<int64_t> null_counts;

    // Combined verdict string; equality of this is arm equivalence.
    std::string combined() const;
};

arrow::Result<OracleReport> compute_oracle(const arrow::Table& table);

// Digest of the Parquet file metadata only (schema + row-group skeleton).
// Used for the T1 metadata workload.
struct MetadataReport {
    std::string digest;
    int64_t num_rows = 0;
    int num_row_groups = 0;
    int num_columns = 0;
};

arrow::Result<MetadataReport> compute_metadata_oracle(const ::parquet::FileMetaData& metadata);

} // namespace dududu::parquet

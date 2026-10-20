#include "dududu/parquet/oracle.hpp"

#include <parquet/metadata.h>
#include <parquet/schema.h>
#include <parquet/types.h>

#include <cinttypes>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>

#include "dududu/parquet/sha256.hpp"

namespace dududu::parquet {

namespace {

std::string digest_of(std::string_view canonical) {
    return sha256_hex(canonical);
}

void append_schema_canonical(const arrow::Schema& schema, std::string* out) {
    for (const auto& field : schema.fields()) {
        out->append(field->name());
        out->push_back(':');
        out->append(field->type()->ToString());
        out->push_back(':');
        out->push_back(field->nullable() ? '1' : '0');
        out->push_back(';');
    }
}

} // namespace

std::string OracleReport::combined() const {
    return "schema=" + schema_sha + " data=" + data_sha + " rows=" + std::to_string(rows);
}

arrow::Result<OracleReport> compute_oracle(const arrow::Table& table) {
    OracleReport report;
    report.rows = table.num_rows();
    report.null_counts.reserve(static_cast<std::size_t>(table.num_columns()));

    std::string schema_canonical;
    append_schema_canonical(*table.schema(), &schema_canonical);
    report.schema_sha = digest_of(schema_canonical);

    Sha256 data;
    char line[128];

    const int len = std::snprintf(line, sizeof(line), "%" PRId64 "\n", report.rows);
    data.update(line, static_cast<std::size_t>(len));

    for (int c = 0; c < table.num_columns(); ++c) {
        const arrow::ChunkedArray& col = *table.column(c);
        report.null_counts.push_back(col.null_count());
        report.decoded_cells += col.length();

        const std::string header = table.field(c)->name() + "\n";
        data.update(header.data(), header.size());

        const auto& type = col.type();
        for (const auto& chunk : col.chunks()) {
            const int64_t n = chunk->length();
            for (int64_t i = 0; i < n; ++i) {
                if (chunk->IsNull(i)) {
                    data.update("N\n", 2);
                    continue;
                }
                if (type->id() == arrow::Type::INT64) {
                    const int64_t v =
                        static_cast<const arrow::Int64Array&>(*chunk).Value(i);
                    const int m = std::snprintf(line, sizeof(line), "i%" PRId64 "\n", v);
                    data.update(line, static_cast<std::size_t>(m));
                } else if (type->id() == arrow::Type::INT32) {
                    const int32_t v =
                        static_cast<const arrow::Int32Array&>(*chunk).Value(i);
                    const int m = std::snprintf(line, sizeof(line), "i%" PRId32 "\n", v);
                    data.update(line, static_cast<std::size_t>(m));
                } else if (type->id() == arrow::Type::DOUBLE) {
                    const double v =
                        static_cast<const arrow::DoubleArray&>(*chunk).Value(i);
                    std::uint64_t bits = 0;
                    if (std::isnan(v)) {
                        // Canonical NaN: every NaN representation collides.
                        bits = 0;
                    } else {
                        std::memcpy(&bits, &v, sizeof(bits));
                    }
                    const int m = std::snprintf(line, sizeof(line), "f%016" PRIx64 "\n",
                                                bits);
                    data.update(line, static_cast<std::size_t>(m));
                } else if (type->id() == arrow::Type::STRING) {
                    const auto& arr = static_cast<const arrow::StringArray&>(*chunk);
                    const auto view = arr.Value(i); // string_view over array data
                    const int m = std::snprintf(line, sizeof(line), "%zx:",
                                                view.size());
                    data.update(line, static_cast<std::size_t>(m));
                    data.update(view.data(), view.size());
                    data.update("\n", 1);
                } else if (type->id() == arrow::Type::BOOL) {
                    const bool v = static_cast<const arrow::BooleanArray&>(*chunk).Value(i);
                    data.update(v ? "1\n" : "0\n", 2);
                } else {
                    return arrow::Status::Invalid("oracle: unsupported column type ",
                                                  type->ToString());
                }
            }
        }
    }

    report.data_sha = data.hex_digest();
    return report;
}

arrow::Result<MetadataReport> compute_metadata_oracle(const ::parquet::FileMetaData& metadata) {
    MetadataReport report;
    report.num_rows = metadata.num_rows();
    report.num_row_groups = metadata.num_row_groups();
    report.num_columns = metadata.num_columns();

    Sha256 s;
    std::string schema_text = metadata.schema()->ToString() + "\n";
    s.update(schema_text.data(), schema_text.size());
    char line[128];
    const int len = std::snprintf(line, sizeof(line), "rows=%" PRId64 " groups=%d\n",
                                  report.num_rows, report.num_row_groups);
    s.update(line, static_cast<std::size_t>(len));
    for (int g = 0; g < report.num_row_groups; ++g) {
        const auto rg = metadata.RowGroup(g);
        const int m =
            std::snprintf(line, sizeof(line),
                          "g%d rows=%" PRId64 " bytes=%" PRId64 " cols=%d\n", g,
                          rg->num_rows(), rg->total_byte_size(), rg->num_columns());
        s.update(line, static_cast<std::size_t>(m));
    }
    report.digest = s.hex_digest();
    return report;
}

} // namespace dududu::parquet

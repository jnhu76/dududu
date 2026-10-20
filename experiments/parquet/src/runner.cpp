#include "dududu/parquet/runner.hpp"

#include <arrow/io/file.h>

#include <chrono>
#include <utility>

#include <parquet/arrow/reader.h>
#include <parquet/metadata.h>

#include "dududu/parquet/adapter_file.hpp"
#include "dududu/parquet/io_decorators.hpp"
#include "dududu/parquet/reader_config.hpp"

namespace dududu::parquet {

namespace {

using clock_type = std::chrono::steady_clock;

double seconds_since(clock_type::time_point t0) {
    return std::chrono::duration<double>(clock_type::now() - t0).count();
}

// T2 projects {shuffle, text}: one numeric, one string column.
const std::vector<int> kT2Projection{1, 4};

struct OpenedFile {
    std::shared_ptr<arrow::io::RandomAccessFile> file;
};

arrow::Result<OpenedFile> open_arm(Arm arm, const std::string& path) {
    OpenedFile out;
    if (arm == Arm::p0_arrow) {
        // P0: Arrow's own file implementation, unmodified. There is no
        // counting hook without replacing the very thing P0 is supposed to
        // be, so its request profile comes from the diagnostic runs instead.
        ARROW_ASSIGN_OR_RAISE(out.file, arrow::io::ReadableFile::Open(path));
        return out;
    }
    ARROW_ASSIGN_OR_RAISE(out.file,
                          AdapterFile::open(std::make_unique<CountingBackend>(make_backend(arm)),
                                            path));
    return out;
}

arrow::Result<IoCounters> counters_of(Arm arm,
                                      const std::shared_ptr<arrow::io::RandomAccessFile>& file) {
    IoCounters empty;
    if (arm == Arm::p0_arrow) {
        return empty;
    }
    auto* adapter = dynamic_cast<AdapterFile*>(file.get());
    if (adapter == nullptr) {
        return arrow::Status::Invalid("runner: non-adapter file for a counting arm");
    }
    auto counting = std::dynamic_pointer_cast<CountingBackend>(adapter->backend());
    if (counting == nullptr) {
        return arrow::Status::Invalid("runner: arm file lacks its counting decorator");
    }
    return counting->counters();
}

} // namespace

const char* workload_name(Workload wl) {
    switch (wl) {
    case Workload::t1_meta: return "t1_meta";
    case Workload::t2_projection: return "t2_projection";
    case Workload::t3_full: return "t3_full";
    }
    return "unknown";
}

const std::vector<int>& projection_columns() {
    return kT2Projection;
}

arrow::Result<RunResult> run_workload(Arm arm, Workload wl, const std::string& path,
                                      const RunOptions& opts) {
    RunResult out;

    auto t0 = clock_type::now();
    ARROW_ASSIGN_OR_RAISE(OpenedFile opened, open_arm(arm, path));
    std::shared_ptr<arrow::io::RandomAccessFile> file = opened.file;

    ::parquet::arrow::FileReaderBuilder builder;
    if (auto st = builder.Open(file); !st.ok()) {
        return st;
    }
    configure_reader(builder); // same frozen reader config on every arm

    if (wl == Workload::t1_meta) {
        // Footer-only workload: schema, row-group skeleton and column counts.
        // Nothing below reads column data; this must never be reported as a
        // scan.
        std::shared_ptr<::parquet::FileMetaData> meta = builder.raw_reader()->metadata();
        if (meta == nullptr) {
            return arrow::Status::IOError("t1: null metadata");
        }
        // Walk the row-group skeleton so T1 actually touches the metadata the
        // footer read delivered.
        for (int g = 0; g < meta->num_row_groups(); ++g) {
            const auto rg = meta->RowGroup(g);
            if (rg == nullptr || rg->num_columns() <= 0) {
                return arrow::Status::IOError("t1: row group ", std::to_string(g),
                                              " metadata missing");
            }
        }
        ARROW_ASSIGN_OR_RAISE(out.metadata, compute_metadata_oracle(*meta));
        out.rows = out.metadata.num_rows;
        out.row_groups = out.metadata.num_row_groups;
        out.columns_read = out.metadata.num_columns;
        out.phases.open_meta_s = seconds_since(t0);
        if (auto st = file->Close(); !st.ok()) {
            return st;
        }
        ARROW_ASSIGN_OR_RAISE(out.counters, counters_of(arm, file));
        return out;
    }

    ARROW_ASSIGN_OR_RAISE(std::unique_ptr<::parquet::arrow::FileReader> reader, builder.Build());
    out.phases.open_meta_s = seconds_since(t0);

    const std::vector<int> columns =
        wl == Workload::t2_projection ? projection_columns() : std::vector<int>{};
    out.columns_read =
        wl == Workload::t2_projection
            ? static_cast<int>(columns.size())
            : static_cast<int>(reader->parquet_reader()->metadata()->num_columns());

    std::shared_ptr<arrow::Table> table;
    t0 = clock_type::now();
    if (auto st =
            columns.empty() ? reader->ReadTable(&table) : reader->ReadTable(columns, &table);
        !st.ok()) {
        return st;
    }
    out.phases.read_s = seconds_since(t0);
    if (table == nullptr) {
        return arrow::Status::IOError("workload produced no table");
    }
    out.rows = table->num_rows();
    out.row_groups =
        static_cast<int>(reader->parquet_reader()->metadata()->num_row_groups());

    if (opts.verify) {
        t0 = clock_type::now();
        ARROW_ASSIGN_OR_RAISE(out.oracle, compute_oracle(*table));
        out.decoded_cells = out.oracle.decoded_cells;
        out.phases.verify_s = seconds_since(t0);
    }

    if (auto st = file->Close(); !st.ok()) {
        return st;
    }
    ARROW_ASSIGN_OR_RAISE(out.counters, counters_of(arm, file));
    return out;
}

} // namespace dududu::parquet

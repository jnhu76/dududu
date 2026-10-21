#include "dududu/parquet/fixture.hpp"

#include <arrow/io/api.h>
#include <parquet/arrow/writer.h>

#include <cmath>
#include <cstdio>
#include <string>
#include <utility>

#include "dududu/parquet/sha256.hpp"

namespace dududu::parquet {

namespace {

// splitmix64 finalizer: the entire data generator. Pure, ordered, seeded by
// the frozen constant below; no global RNG state anywhere.
constexpr std::uint64_t kSeed = 0xD4D4D420261020ULL;

std::uint64_t mix64(std::uint64_t x) {
    x += kSeed;
    x ^= x >> 30;
    x *= 0xBF58476D1CE4E5B9ULL;
    x ^= x >> 27;
    x *= 0x94D049BB133111EBULL;
    x ^= x >> 31;
    return x;
}

std::uint64_t cell_hash(int64_t row, unsigned tag) {
    return mix64(static_cast<std::uint64_t>(row) * 0x9E3779B97F4A7C15ULL +
                 static_cast<std::uint64_t>(tag) * 0x100000001B3ULL);
}

constexpr char kAlphabet[] = "abcdefghijklmnopqrstuvwxyz0123456789_-ABCDEFGHIJKLMNOPQRSTUVWXYZ";

std::string make_text(int64_t row, unsigned tag, int64_t max_len) {
    const std::uint64_t h = cell_hash(row, tag);
    const int64_t len = static_cast<int64_t>(h % static_cast<std::uint64_t>(max_len + 1));
    std::string out(static_cast<std::size_t>(len), '\0');
    for (int64_t i = 0; i < len; ++i) {
        out[static_cast<std::size_t>(i)] = kAlphabet[cell_hash(row * 1315423911ULL + i, tag) %
                                                      (sizeof(kAlphabet) - 1)];
    }
    return out;
}

constexpr int kTagShuffle = 1;
constexpr int kTagI32 = 2;
constexpr int kTagF64 = 3;
constexpr int kTagText = 4;
constexpr int kTagWide = 5;
constexpr int kTagFlag = 6;

arrow::Result<std::shared_ptr<arrow::Table>> make_table(const FixtureSpec& spec) {
    const int64_t n = spec.rows;

    arrow::Int64Builder id_builder, shuffle_builder;
    arrow::Int32Builder i32_builder;
    arrow::DoubleBuilder f64_builder;
    arrow::StringBuilder text_builder, wide_builder;
    arrow::BooleanBuilder flag_builder;

    // Reserve generously; these are hints, not requirements.
    static_cast<void>(id_builder.Reserve(n));
    static_cast<void>(shuffle_builder.Reserve(n));
    static_cast<void>(i32_builder.Reserve(n));
    static_cast<void>(f64_builder.Reserve(n));
    static_cast<void>(flag_builder.Reserve(n));

    for (int64_t row = 0; row < n; ++row) {
        ARROW_RETURN_NOT_OK(id_builder.Append(row));

        const std::uint64_t sh = cell_hash(row, kTagShuffle);
        ARROW_RETURN_NOT_OK(shuffle_builder.Append(static_cast<int64_t>(sh % static_cast<std::uint64_t>(n))));

        if (cell_hash(row, kTagI32) % 100 < 10) {
            ARROW_RETURN_NOT_OK(i32_builder.AppendNull());
        } else {
            ARROW_RETURN_NOT_OK(
                i32_builder.Append(static_cast<int32_t>(cell_hash(row, kTagI32) >> 32)));
        }

        if (cell_hash(row, kTagF64) % 100 < 5) {
            ARROW_RETURN_NOT_OK(f64_builder.AppendNull());
        } else {
            const double v = static_cast<double>(static_cast<int64_t>(cell_hash(row, kTagF64) >> 8)) / 4096.0;
            ARROW_RETURN_NOT_OK(f64_builder.Append(v));
        }

        ARROW_RETURN_NOT_OK(text_builder.Append(make_text(row, kTagText, 24)));
        ARROW_RETURN_NOT_OK(wide_builder.Append(make_text(row, kTagWide, 192)));

        if (cell_hash(row, kTagFlag) % 100 < 25) {
            ARROW_RETURN_NOT_OK(flag_builder.AppendNull());
        } else {
            ARROW_RETURN_NOT_OK(flag_builder.Append(((cell_hash(row, kTagFlag) >> 56) & 1) != 0));
        }
    }

    ARROW_ASSIGN_OR_RAISE(auto id, id_builder.Finish());
    ARROW_ASSIGN_OR_RAISE(auto shuffle, shuffle_builder.Finish());
    ARROW_ASSIGN_OR_RAISE(auto i32, i32_builder.Finish());
    ARROW_ASSIGN_OR_RAISE(auto f64, f64_builder.Finish());
    ARROW_ASSIGN_OR_RAISE(auto text, text_builder.Finish());
    ARROW_ASSIGN_OR_RAISE(auto wide, wide_builder.Finish());
    ARROW_ASSIGN_OR_RAISE(auto flag, flag_builder.Finish());

    auto schema = arrow::schema(
        {arrow::field("id", arrow::int64(), false),
         arrow::field("shuffle", arrow::int64(), false),
         arrow::field("i32_null10", arrow::int32(), true),
         arrow::field("f64_null5", arrow::float64(), true),
         arrow::field("text", arrow::utf8(), false),
         arrow::field("wide", arrow::utf8(), false),
         arrow::field("flag_null25", arrow::boolean(), true)});

    return arrow::Table::Make(std::move(schema),
                              {std::move(id), std::move(shuffle), std::move(i32),
                               std::move(f64), std::move(text), std::move(wide),
                               std::move(flag)});
}

} // namespace

const FixtureSpec* find_fixture_spec(const std::string& name) {
    // Frozen parameters. Medium targets the 64-256 MiB band on the verified
    // host; actual bytes land in the manifest.
    static const FixtureSpec specs[] = {
        {"small", 40000, {6000, 10000, 6000, 10000, 6000, 2000}},
        {"medium", 1200000, {160000, 140000, 160000, 140000, 160000, 140000, 160000, 140000}},
    };
    for (const FixtureSpec& s : specs) {
        if (name == s.name) {
            return &s;
        }
    }
    return nullptr;
}

int num_fixture_columns() {
    return 7;
}

arrow::Result<std::shared_ptr<arrow::Table>> build_fixture_table(const FixtureSpec& spec) {
    int64_t sum = 0;
    for (int64_t g : spec.group_sizes) {
        sum += g;
    }
    if (sum != spec.rows) {
        return arrow::Status::Invalid("fixture spec group sizes (", std::to_string(sum),
                                      ") do not sum to rows (", std::to_string(spec.rows), ")");
    }
    return make_table(spec);
}

arrow::Status write_fixture_parquet(const arrow::Table& table, const FixtureSpec& spec,
                                    const std::string& compression, const std::string& path) {
    ::parquet::WriterProperties::Builder wp;
    if (compression == "none") {
        wp.compression(::parquet::Compression::UNCOMPRESSED);
    } else if (compression == "snappy") {
        // No availability probe exists in this Arrow packaging; an actually
        // missing codec surfaces as an explicit writer error below — never
        // as a silent fallback to uncompressed.
        wp.compression(::parquet::Compression::SNAPPY);
    } else {
        return arrow::Status::Invalid("unknown compression: ", compression);
    }
    // Frozen writer shape: dictionary on (default), Parquet 2.6, data page v2
    // off. Whatever is decided here must be recorded in the manifest.
    wp.version(::parquet::ParquetVersion::PARQUET_2_6);
    wp.data_page_version(::parquet::ParquetDataPageVersion::V1);
    std::shared_ptr<::parquet::WriterProperties> props = wp.build();
    std::shared_ptr<::parquet::ArrowWriterProperties> arrow_props =
        ::parquet::default_arrow_writer_properties();

    ARROW_ASSIGN_OR_RAISE(auto sink, arrow::io::FileOutputStream::Open(path));
    ARROW_ASSIGN_OR_RAISE(
        auto writer, ::parquet::arrow::FileWriter::Open(*table.schema(),
                                                      arrow::default_memory_pool(), sink,
                                                      props, arrow_props));
    int64_t offset = 0;
    for (int64_t g : spec.group_sizes) {
        ARROW_RETURN_NOT_OK(writer->NewRowGroup());
        for (int c = 0; c < table.num_columns(); ++c) {
            ARROW_RETURN_NOT_OK(writer->WriteColumnChunk(table.column(c), offset, g));
        }
        offset += g;
    }
    ARROW_RETURN_NOT_OK(writer->Close());
    ARROW_RETURN_NOT_OK(sink->Close());
    return arrow::Status::OK();
}

arrow::Result<GeneratedFixture> generate_fixture(const std::string& name,
                                                 const std::string& out_dir,
                                                 const std::string& compression) {
    const FixtureSpec* spec = find_fixture_spec(name);
    if (spec == nullptr) {
        return arrow::Status::Invalid("unknown fixture dataset: ", name);
    }
    ARROW_ASSIGN_OR_RAISE(auto table, build_fixture_table(*spec));

    GeneratedFixture out;
    out.path = out_dir + "/" + name + "-" + compression + ".parquet";
    ARROW_RETURN_NOT_OK(write_fixture_parquet(*table, *spec, compression, out.path));

    out.sha256 = sha256_file(out.path);
    if (out.sha256.empty()) {
        return arrow::Status::IOError("generated fixture digest failed: ", out.path);
    }
    FILE* f = std::fopen(out.path.c_str(), "rb");
    if (f == nullptr) {
        return arrow::Status::IOError("generated fixture unreadable: ", out.path);
    }
    std::fseek(f, 0, SEEK_END);
    out.bytes = static_cast<int64_t>(std::ftell(f));
    std::fclose(f);
    return out;
}

} // namespace dududu::parquet

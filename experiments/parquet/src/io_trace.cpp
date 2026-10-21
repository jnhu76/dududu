#include "dududu/parquet/io_trace.hpp"

#include <arrow/status.h>

#include <algorithm>
#include <cerrno>
#include <charconv>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

#include <parquet/arrow/reader.h>

#include "dududu/parquet/adapter_file.hpp"
#include "dududu/parquet/io_decorators.hpp"
#include "dududu/parquet/reader_config.hpp"
#include "dududu/parquet/runner.hpp"
#include "dududu/parquet/sha256.hpp"

namespace dududu::parquet {

namespace {

constexpr const char* kTraceType = "dududu-parquet-io-trace";
constexpr int kTraceVersion = 1;

std::string esc(const std::string& s) {
    std::string out;
    for (char c : s) {
        if (c == '"' || c == '\\') {
            out.push_back('\\');
        }
        out.push_back(c);
    }
    return out;
}

// The trace reader below is fail-closed: a missing or malformed key is a
// parse failure, never a silent zero/empty fallback. The on-disk format is
// JSON Lines (one JSON object per line), so every accepted line must also
// look like an object. Structural JSON validity beyond these field checks is
// enforced independently of this parser by `benchmarks/parquet/validate-trace.sh`
// (jq) in the protocol; the two layers must not share code.

bool require_object_line(std::string_view line) {
    return !line.empty() && line.front() == '{' && line.back() == '}';
}

std::string_view json_string_value(std::string_view line, std::string_view key, bool* found) {
    const std::string needle = "\"" + std::string(key) + "\":\"";
    const auto p = line.find(needle);
    if (p == std::string_view::npos) {
        *found = false;
        return {};
    }
    const auto start = p + needle.size();
    const auto end = line.find('"', start);
    if (end == std::string_view::npos) {
        *found = false;
        return {};
    }
    *found = true;
    return line.substr(start, end - start);
}

bool json_uint_value(std::string_view line, std::string_view key, std::uint64_t* out) {
    const std::string needle = "\"" + std::string(key) + "\":";
    const auto p = line.find(needle);
    if (p == std::string_view::npos) {
        return false;
    }
    const auto start = p + needle.size();
    std::uint64_t v = 0;
    const auto [ptr, ec] = std::from_chars(line.data() + start, line.data() + line.size(), v);
    if (ec != std::errc() || ptr == line.data() + start) {
        return false;
    }
    *out = v;
    return true;
}

bool json_bool_value(std::string_view line, std::string_view key, bool* out) {
    const std::string t = "\"" + std::string(key) + "\":true";
    const std::string f = "\"" + std::string(key) + "\":false";
    if (line.find(t) != std::string_view::npos) {
        *out = true;
        return true;
    }
    if (line.find(f) != std::string_view::npos) {
        *out = false;
        return true;
    }
    return false;
}

bool is_lower_hex(std::string_view s) {
    if (s.size() != 64) {
        return false;
    }
    for (char c : s) {
        const bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        if (!ok) {
            return false;
        }
    }
    return true;
}

// Strict: an unknown workload name must fail the capture, never fall back
// to a full scan under a typo's label.
bool workload_from_name(const std::string& name, Workload* out) {
    if (name == "t1_meta") {
        *out = Workload::t1_meta;
        return true;
    }
    if (name == "t2_projection") {
        *out = Workload::t2_projection;
        return true;
    }
    if (name == "t3_full") {
        *out = Workload::t3_full;
        return true;
    }
    return false;
}

} // namespace

std::string serialize_trace(const TraceFile& trace) {
    std::string out;
    out.reserve(64 + trace.requests.size() * 80);
    out += "{\"type\":\"" + std::string(kTraceType) + "\",\"version\":" +
           std::to_string(kTraceVersion);
    out += ",\"dataset_sha\":\"" + esc(trace.dataset_sha) + "\"";
    out += ",\"dataset_path\":\"" + esc(trace.dataset_path) + "\"";
    out += ",\"workload\":\"" + esc(trace.workload) + "\"";
    out += ",\"arm\":\"" + esc(trace.arm) + "\"";
    out += ",\"file_size\":" + std::to_string(trace.file_size) + "}\n";
    for (const TraceRequest& r : trace.requests) {
        out += "{\"i\":" + std::to_string(r.index) + ",\"offset\":" +
               std::to_string(r.offset) + ",\"requested\":" + std::to_string(r.requested) +
               ",\"returned\":" + std::to_string(r.returned) + ",\"ok\":" +
               (r.ok ? "true" : "false") + "}\n";
    }
    return out;
}

bool parse_trace(std::string_view text, TraceFile* out) {
    if (out == nullptr) {
        return false;
    }
    *out = TraceFile{};
    std::size_t pos = 0;
    bool first = true;
    std::size_t expect_index = 0;
    while (pos < text.size()) {
        const auto eol = text.find('\n', pos);
        if (eol == std::string_view::npos) {
            return false; // unterminated trailing line: truncated file, not a trace
        }
        const std::string_view line = text.substr(pos, eol - pos);
        pos = eol + 1;
        if (line.empty()) {
            return false; // JSON Lines has no blank records
        }
        if (!require_object_line(line)) {
            return false;
        }
        if (first) {
            first = false;
            bool found = false;
            std::uint64_t version = 0;
            if (json_string_value(line, "type", &found) != kTraceType || !found) {
                return false;
            }
            if (!json_uint_value(line, "version", &version) ||
                version != static_cast<std::uint64_t>(kTraceVersion)) {
                return false;
            }
            const std::string_view dataset_sha = json_string_value(line, "dataset_sha", &found);
            if (!found || !is_lower_hex(dataset_sha)) {
                return false;
            }
            const std::string_view dataset_path =
                json_string_value(line, "dataset_path", &found);
            if (!found || dataset_path.empty()) {
                return false;
            }
            const std::string_view workload = json_string_value(line, "workload", &found);
            if (!found || workload.empty()) {
                return false;
            }
            const std::string_view arm = json_string_value(line, "arm", &found);
            if (!found || arm.empty()) {
                return false;
            }
            std::uint64_t file_size = 0;
            if (!json_uint_value(line, "file_size", &file_size) || file_size == 0) {
                return false;
            }
            out->dataset_sha = std::string(dataset_sha);
            out->dataset_path = std::string(dataset_path);
            out->workload = std::string(workload);
            out->arm = std::string(arm);
            out->file_size = file_size;
            continue;
        }
        TraceRequest r;
        if (!json_uint_value(line, "i", &r.index) || r.index != expect_index) {
            return false; // indices are dense and zero-based
        }
        if (!json_uint_value(line, "offset", &r.offset) ||
            !json_uint_value(line, "requested", &r.requested) ||
            !json_uint_value(line, "returned", &r.returned)) {
            return false;
        }
        if (!json_bool_value(line, "ok", &r.ok)) {
            return false;
        }
        if (r.requested == 0) {
            return false; // the reader never issues empty reads; a zero is corruption
        }
        if (r.returned > r.requested) {
            return false;
        }
        if (r.offset > out->file_size || r.offset + r.returned > out->file_size) {
            return false; // reads live inside the captured file
        }
        out->requests.push_back(r);
        ++expect_index;
    }
    return !first;
}

arrow::Status capture_trace_to_file(Arm arm, const std::string& workload_name_str,
                                    const std::string& parquet_path,
                                    const std::string& out_path) {
    // The capture arm is always one of the instrumented arms.
    if (arm == Arm::p0_arrow) {
        return arrow::Status::Invalid("trace capture needs an instrumented arm (p1/p2)");
    }

    std::vector<TraceEntry> entries;
    ARROW_ASSIGN_OR_RAISE(auto file,
                          AdapterFile::open(
                              std::make_unique<TracingBackend>(
                                  std::make_unique<CountingBackend>(make_backend(arm)), &entries),
                              parquet_path));

    ::parquet::arrow::FileReaderBuilder builder;
    if (auto st = builder.Open(file); !st.ok()) {
        return st;
    }
    configure_reader(builder); // capture the same config the timed arms see
    Workload workload;
    if (!workload_from_name(workload_name_str, &workload)) {
        return arrow::Status::Invalid("capture: unknown workload name: ",
                                      workload_name_str);
    }
    if (workload != Workload::t1_meta) {
        ARROW_ASSIGN_OR_RAISE(auto reader, builder.Build());
        std::shared_ptr<arrow::Table> table;
        if (auto st = workload == Workload::t2_projection
                          ? reader->ReadTable(projection_columns(), &table)
                          : reader->ReadTable(&table);
            !st.ok()) {
            return st;
        }
        if (table == nullptr) {
            return arrow::Status::IOError("trace capture produced no table");
        }
    }
    if (auto st = file->Close(); !st.ok()) {
        return st;
    }

    TraceFile trace;
    // Diagnostic evidence, never a timing sample; hashing the file here is
    // fine and keeps the trace self-describing. An empty digest means the
    // file could not be read — a trace without a dataset identity is not
    // evidence, so fail instead of recording one.
    trace.dataset_sha = sha256_file(parquet_path);
    if (trace.dataset_sha.empty()) {
        return arrow::Status::IOError("capture: dataset digest failed: ", parquet_path);
    }
    trace.dataset_path = parquet_path;
    trace.workload = workload_name_str;
    trace.arm = arm_name(arm);

    // file size via the same backend family (size() is not a data read).
    {
        auto backend = make_backend(arm);
        if (auto st = backend->open(parquet_path); !st.ok()) {
            return st;
        }
        ARROW_ASSIGN_OR_RAISE(int64_t fsize, backend->size());
        trace.file_size = static_cast<std::uint64_t>(fsize);
        if (auto st = backend->close(); !st.ok()) {
            return st;
        }
    }

    trace.requests.reserve(entries.size());
    for (std::size_t i = 0; i < entries.size(); ++i) {
        const TraceEntry& e = entries[i];
        TraceRequest r;
        r.index = i;
        r.offset = e.offset;
        r.requested = e.requested;
        r.returned = e.returned;
        r.ok = e.ok;
        trace.requests.push_back(r);
    }

    const std::string text = serialize_trace(trace);
    FILE* f = std::fopen(out_path.c_str(), "wb");
    if (f == nullptr) {
        return arrow::Status::IOError("trace write open failed: ", std::strerror(errno));
    }
    if (std::fwrite(text.data(), 1, text.size(), f) != text.size()) {
        std::fclose(f);
        return arrow::Status::IOError("trace write failed: ", out_path);
    }
    if (std::fclose(f) != 0) {
        return arrow::Status::IOError("trace close failed: ", out_path);
    }
    return arrow::Status::OK();
}

ReplayOutcome replay_trace(IoBackend& backend, const TraceFile& trace) {
    ReplayOutcome out;
    std::vector<std::byte> buf;
    std::size_t max_len = 1;
    for (const TraceRequest& r : trace.requests) {
        max_len = std::max<std::size_t>(max_len, static_cast<std::size_t>(r.requested));
    }
    buf.resize(max_len);

    for (const TraceRequest& r : trace.requests) {
        if (!r.ok) {
            out.mismatches.push_back("trace request " + std::to_string(r.index) +
                                     " was a failed read; replay needs successful traces");
            return out;
        }
        if (r.requested == 0) {
            ++out.requests;
            continue;
        }
        auto got = backend.read_at(static_cast<int64_t>(r.offset),
                                   static_cast<int64_t>(r.requested), buf.data());
        if (!got.ok()) {
            out.mismatches.push_back("request " + std::to_string(r.index) + " failed: " +
                                     got.status().ToString());
            return out;
        }
        if (static_cast<uint64_t>(got.ValueOrDie()) != r.returned) {
            out.mismatches.push_back("request " + std::to_string(r.index) + " returned " +
                                     std::to_string(got.ValueOrDie()) + " expected " +
                                     std::to_string(r.returned));
            return out;
        }
        // Consume the bytes: the checksum forces every returned byte through
        // the CPU, so a backend cannot win by skipping the copy it promised.
        const std::byte* p = buf.data();
        std::uint64_t h = out.fnv;
        for (std::size_t i = 0; i < static_cast<std::size_t>(got.ValueOrDie()); ++i) {
            h ^= static_cast<std::uint64_t>(p[i]);
            h *= 0x100000001B3ULL;
        }
        out.fnv = h;
        out.bytes += static_cast<std::uint64_t>(got.ValueOrDie());
        ++out.requests;
    }
    return out;
}

arrow::Result<ReplayOutcome> replay_trace_file(const std::string& backend_name,
                                               const TraceFile& trace,
                                               bool verify_dataset) {
    if (trace.dataset_path.empty()) {
        return arrow::Status::Invalid("trace lacks dataset_path; cannot replay");
    }
    if (verify_dataset && !trace.dataset_sha.empty()) {
        // The trace is only evidence for the bytes it was captured over. A
        // regenerated or mutated dataset (even same-length) must not replay
        // under the old identity.
        const std::string actual = sha256_file(trace.dataset_path);
        if (actual.empty()) {
            return arrow::Status::IOError("replay: dataset digest failed: ",
                                          trace.dataset_path);
        }
        if (actual != trace.dataset_sha) {
            return arrow::Status::Invalid(
                "replay: dataset changed since capture: ", trace.dataset_path,
                " captured=", trace.dataset_sha, " actual=", actual);
        }
    }
    std::unique_ptr<IoBackend> backend =
        backend_name == "native" ? make_native_backend() : make_sluice_backend();
    if (auto st = backend->open(trace.dataset_path); !st.ok()) {
        return st;
    }
    ReplayOutcome out = replay_trace(*backend, trace);
    if (auto st = backend->close(); !st.ok()) {
        return st;
    }
    return out;
}

} // namespace dududu::parquet

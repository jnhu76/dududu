// Trace capture/replay evidence: the captured request list is a real
// Parquet reader's I/O, is identical across the instrumented arms, and
// replays byte-faithfully through both backends.

#include <algorithm>
#include <cstdio>
#include <string>
#include <unistd.h>
#include <vector>

#include "dududu/parquet/fixture.hpp"
#include "dududu/parquet/io_backend.hpp"
#include "dududu/parquet/io_trace.hpp"
#include "dududu/parquet/runner.hpp"

using namespace dududu::parquet;

namespace {

int failures = 0;

#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            ++failures;                                                          \
        }                                                                        \
    } while (0)

std::string make_temp_dir() {
    std::string tmpl = "/tmp/dududu_parquet_trace_XXXXXX";
    std::vector<char> buf(tmpl.begin(), tmpl.end());
    buf.push_back('\0');
    if (mkdtemp(buf.data()) == nullptr) {
        return "";
    }
    return buf.data();
}

bool read_file(const std::string& path, std::string* out) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (f == nullptr) {
        return false;
    }
    char buf[65536];
    std::size_t n;
    while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) {
        out->append(buf, n);
    }
    std::fclose(f);
    return true;
}

} // namespace

int main() {
    const std::string dir = make_temp_dir();
    if (dir.empty()) {
        std::fprintf(stderr, "trace: temp dir failed\n");
        return 1;
    }
    auto gen = generate_fixture("small", dir, "none");
    if (!gen.ok()) {
        std::fprintf(stderr, "trace: fixture failed: %s\n", gen.status().ToString().c_str());
        return 1;
    }
    const std::string path = gen.ValueOrDie().path;
    const std::string sha = gen.ValueOrDie().sha256;

    // --- capture: both instrumented arms, full scan --------------------------
    const std::string t1 = dir + "/trace-p1-t3.jsonl";
    const std::string t2 = dir + "/trace-p2-t3.jsonl";
    CHECK(capture_trace_to_file(Arm::p1_native, "t3_full", path, t1).ok());
    CHECK(capture_trace_to_file(Arm::p2_sluice, "t3_full", path, t2).ok());

    std::string text1, text2;
    CHECK(read_file(t1, &text1));
    CHECK(read_file(t2, &text2));

    TraceFile trace1, trace2;
    CHECK(parse_trace(text1, &trace1));
    CHECK(parse_trace(text2, &trace2));

    // The reader must behave identically over both arms: same request list.
    CHECK(trace1.requests.size() == trace2.requests.size());
    CHECK(trace1.requests.size() > 10); // a real workload, not a degenerate stub
    CHECK(trace1.dataset_sha == sha);
    CHECK(trace2.dataset_sha == sha);
    for (std::size_t i = 0; i < trace1.requests.size(); ++i) {
        if (trace1.requests[i].offset != trace2.requests[i].offset ||
            trace1.requests[i].requested != trace2.requests[i].requested ||
            trace1.requests[i].returned != trace2.requests[i].returned) {
            std::fprintf(stderr, "trace divergence at %zu\n", i);
            CHECK(false);
            break;
        }
    }

    // Sanity of the request profile: reads cover data regions inside the file
    // and actually moved the bytes the file holds (full scan).
    uint64_t returned_total = 0;
    uint64_t max_off = 0;
    for (const auto& r : trace1.requests) {
        CHECK(r.ok);
        returned_total += r.returned;
        max_off = std::max(max_off, r.offset);
    }
    CHECK(max_off < trace1.file_size);
    // Full scan: the column chunks plus footer come back over the trace.
    CHECK(returned_total >= gen.ValueOrDie().bytes / 2);

    // --- projection trace really prunes ---------------------------------------
    const std::string t3 = dir + "/trace-p1-t2.jsonl";
    CHECK(capture_trace_to_file(Arm::p1_native, "t2_projection", path, t3).ok());
    std::string text3;
    CHECK(read_file(t3, &text3));
    TraceFile trace3;
    CHECK(parse_trace(text3, &trace3));
    uint64_t projected_requested = 0;
    for (const auto& r : trace3.requests) {
        projected_requested += r.requested;
    }
    uint64_t full_requested = 0;
    for (const auto& r : trace1.requests) {
        full_requested += r.requested;
    }
    CHECK(projected_requested < full_requested);

    // --- replay: both backends, byte-faithful, identical checksums ------------
    auto rn = replay_trace_file("native", trace1);
    auto rs = replay_trace_file("sluice", trace1);
    CHECK(rn.ok() && rs.ok());
    if (rn.ok() && rs.ok()) {
        CHECK(rn.ValueOrDie().ok());
        CHECK(rs.ValueOrDie().ok());
        CHECK(rn.ValueOrDie().fnv == rs.ValueOrDie().fnv);
        CHECK(rn.ValueOrDie().requests == trace1.requests.size());
        CHECK(rn.ValueOrDie().bytes == returned_total);
    }

    // --- replay against a corrupted trace must be caught ----------------------
    {
        TraceFile corrupted = trace1;
        if (!corrupted.requests.empty()) {
            corrupted.requests[0].returned += 1; // lie about one byte count
            auto rb = replay_trace_file("native", corrupted);
            CHECK(rb.ok() && !rb.ValueOrDie().ok()); // mismatch must be detected
        }
    }

    // --- parser admission: malformed traces must fail closed ------------------
    // The capture above must also survive its own serialization unchanged.
    {
        TraceFile rt;
        CHECK(parse_trace(text1, &rt));
        CHECK(serialize_trace(rt) == text1);
    }
    {
        const std::string digest(64, 'a'); // shape of a sha256 hex digest
        const std::string header =
            "{\"type\":\"dududu-parquet-io-trace\",\"version\":1,"
            "\"dataset_sha\":\"" +
            digest +
            "\",\"dataset_path\":\"/tmp/x.parquet\",\"workload\":\"t3_full\","
            "\"arm\":\"p1-native\",\"file_size\":1000}\n";
        const std::string req =
            "{\"i\":0,\"offset\":0,\"requested\":64,\"returned\":64,\"ok\":true}\n";

        TraceFile sink;
        TraceFile good;
        CHECK(parse_trace(header + req, &good));
        CHECK(good.file_size == 1000 && good.requests.size() == 1);

        // The exact regression this guards: a header line that lost its
        // closing brace is not a JSON object and must be rejected.
        CHECK(!parse_trace(header.substr(0, header.size() - 2) + "\n" + req, &sink));
        // Missing required header fields.
        CHECK(!parse_trace(
            "{\"type\":\"dududu-parquet-io-trace\",\"version\":1,\"dataset_sha\":\"" +
                digest +
                "\",\"dataset_path\":\"/tmp/x.parquet\",\"workload\":\"t3_full\","
                "\"arm\":\"p1-native\"}\n" +
                req,
            &sink));
        CHECK(!parse_trace(
            "{\"type\":\"dududu-parquet-io-trace\",\"version\":1,\"dataset_sha\":\"abc\","
            "\"dataset_path\":\"/tmp/x.parquet\",\"workload\":\"t3_full\","
            "\"arm\":\"p1-native\",\"file_size\":1000}\n" +
                req,
            &sink));
        // Request records: missing field, non-dense index, impossible counts,
        // out-of-file offsets.
        CHECK(!parse_trace(
            header + "{\"i\":0,\"offset\":0,\"requested\":64,\"ok\":true}\n", &sink));
        CHECK(!parse_trace(
            header +
                "{\"i\":1,\"offset\":0,\"requested\":64,\"returned\":64,\"ok\":true}\n",
            &sink));
        CHECK(!parse_trace(
            header + "{\"i\":0,\"offset\":0,\"requested\":8,\"returned\":9,\"ok\":true}\n",
            &sink));
        CHECK(!parse_trace(
            header +
                "{\"i\":0,\"offset\":2000,\"requested\":8,\"returned\":8,\"ok\":true}\n",
            &sink));
        // Structural: unterminated final line, blank line between records.
        CHECK(!parse_trace(
            header + "{\"i\":0,\"offset\":0,\"requested\":8,\"returned\":8,\"ok\":true}",
            &sink));
        CHECK(!parse_trace(header + "\n" + req, &sink));
    }

    if (failures != 0) {
        std::fprintf(stderr, "parquet_trace_test: %d failure(s)\n", failures);
        return 1;
    }
    std::printf("parquet_trace_test: PASS (requests=%zu returned=%llu fnv=%016llx)\n",
                trace1.requests.size(),
                static_cast<unsigned long long>(returned_total),
                static_cast<unsigned long long>(rn.ValueOrDie().fnv));
    return 0;
}

// parquet_trace: untimed diagnostic capture of the reader's ReadAt requests.
//
//   parquet_trace --file <parquet> --workload t1_meta|t2_projection|t3_full
//                 --arm p1-native|p2-sluice --out <trace.jsonl>
//
// This is evidence, not a timing sample: no phase here is measured.

#include <cstdio>
#include <string>

#include "dududu/parquet/io_backend.hpp"
#include "dududu/parquet/io_trace.hpp"

namespace {

void usage() {
    std::fputs("usage: parquet_trace --file <parquet> --workload t1_meta|t2_projection|t3_full"
               " --arm p1-native|p2-sluice --out <trace.jsonl>\n",
               stderr);
}

} // namespace

int main(int argc, char** argv) {
    using namespace dududu::parquet;

    std::string file, workload, arm, out;
    for (int i = 1; i < argc; ++i) {
        const auto arg = std::string(argv[i]);
        auto next = [&]() -> const char* { return i + 1 < argc ? argv[i + 1] : nullptr; };
        if (arg == "--file" && next() != nullptr) {
            file = next();
            ++i;
        } else if (arg == "--workload" && next() != nullptr) {
            workload = next();
            ++i;
        } else if (arg == "--arm" && next() != nullptr) {
            arm = next();
            ++i;
        } else if (arg == "--out" && next() != nullptr) {
            out = next();
            ++i;
        } else {
            usage();
            return 2;
        }
    }
    if (file.empty() || workload.empty() || arm.empty() || out.empty()) {
        usage();
        return 2;
    }

    Arm arm_id;
    if (arm == "p1-native") {
        arm_id = Arm::p1_native;
    } else if (arm == "p2-sluice") {
        arm_id = Arm::p2_sluice;
    } else {
        std::fprintf(stderr, "parquet_trace: unknown arm %s\n", arm.c_str());
        return 2;
    }

    if (auto st = capture_trace_to_file(arm_id, workload, file, out); !st.ok()) {
        std::fprintf(stderr, "parquet_trace: %s\n", st.ToString().c_str());
        return 1;
    }

    TraceFile parsed;
    std::string text;
    FILE* f = std::fopen(out.c_str(), "rb");
    if (f != nullptr) {
        char buf[4096];
        std::size_t n;
        while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) {
            text.append(buf, n);
        }
        std::fclose(f);
    }
    if (!parse_trace(text, &parsed)) {
        std::fprintf(stderr, "parquet_trace: written trace failed to parse\n");
        return 1;
    }
    uint64_t requested = 0, returned = 0;
    for (const auto& r : parsed.requests) {
        requested += r.requested;
        returned += r.returned;
    }
    std::printf("parquet_trace: %s workload=%s arm=%s dataset_sha=%s requests=%zu "
                "requested=%llu returned=%llu file_size=%llu\n",
                out.c_str(), parsed.workload.c_str(), parsed.arm.c_str(),
                parsed.dataset_sha.c_str(), parsed.requests.size(),
                static_cast<unsigned long long>(requested),
                static_cast<unsigned long long>(returned),
                static_cast<unsigned long long>(parsed.file_size));
    return 0;
}

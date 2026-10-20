// parquet_bench: Google Benchmark entry point for the R1 standalone arms.
//
//   parquet_bench --small=<path> --medium=<path> [--trace=<trace.jsonl>] \
//       [Google Benchmark flags]
//
// Registration order interleaves the arms per workload (P0, P1, P2), so a
// sampled pass walks the three arms of a workload back-to-back on a warm
// cache. Each iteration is one full workload run with identical phase
// boundaries on every arm; oracle verification is never inside the measured
// loop. Phase splits and I/O counters ride along as benchmark counters.

#include <benchmark/benchmark.h>

#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "dududu/parquet/io_backend.hpp"
#include "dududu/parquet/io_trace.hpp"
#include "dududu/parquet/runner.hpp"
#include "dududu/parquet/sha256.hpp"

namespace {

using dududu::parquet::Arm;
using dududu::parquet::Workload;

struct Datasets {
    std::string small;
    std::string medium;
    std::string trace;
};

Datasets g_datasets;
std::mutex g_trace_mutex;
std::unordered_map<std::string, dududu::parquet::TraceFile> g_traces;

const dududu::parquet::TraceFile* trace_for(const std::string& path) {
    std::lock_guard lock(g_trace_mutex);
    auto it = g_traces.find(path);
    return it == g_traces.end() ? nullptr : &it->second;
}

bool load_trace(const std::string& path) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (f == nullptr) {
        std::fprintf(stderr, "parquet_bench: cannot open trace %s\n", path.c_str());
        return false;
    }
    std::string text;
    char buf[65536];
    std::size_t n;
    while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) {
        text.append(buf, n);
    }
    std::fclose(f);
    auto trace = std::make_unique<dududu::parquet::TraceFile>();
    if (!dududu::parquet::parse_trace(text, trace.get())) {
        std::fprintf(stderr, "parquet_bench: trace parse failed: %s\n", path.c_str());
        return false;
    }
    std::lock_guard lock(g_trace_mutex);
    g_traces[path] = std::move(*trace);
    return true;
}

void add_counters(benchmark::State& st, const dududu::parquet::RunResult& r) {
    if (st.threads() != 1) {
        return; // counters are not thread-safe; multi-thread runs report time only
    }
    st.counters["open_meta_ms"] = r.phases.open_meta_s * 1000.0;
    st.counters["read_ms"] = r.phases.read_s * 1000.0;
    st.counters["rows"] = benchmark::Counter(static_cast<double>(r.rows));
    // Logical cells touched per iteration (rows x columns read). The verified
    // decoded-cell count lives in the oracle tests; the benchmark loop does
    // not pay for verification.
    st.counters["cells"] = benchmark::Counter(
        static_cast<double>(r.rows * r.columns_read));
    st.counters["columns_read"] =
        benchmark::Counter(static_cast<double>(r.columns_read));
    st.counters["io_calls"] = benchmark::Counter(static_cast<double>(r.counters.read_at_calls));
    st.counters["requested_bytes"] =
        benchmark::Counter(static_cast<double>(r.counters.requested_bytes));
    st.counters["returned_bytes"] =
        benchmark::Counter(static_cast<double>(r.counters.returned_bytes));
    st.counters["read_errors"] =
        benchmark::Counter(static_cast<double>(r.counters.read_errors));
}

void bm_workload(benchmark::State& st, Arm arm, Workload wl, const std::string& path) {
    dududu::parquet::RunOptions opts; // verify stays off inside the timed loop
    for (auto _ : st) {
        auto r = dududu::parquet::run_workload(arm, wl, path, opts);
        if (!r.ok()) {
            st.SkipWithError(r.status().ToString().c_str());
            return;
        }
        add_counters(st, *r);
        benchmark::DoNotOptimize(r->rows);
        benchmark::ClobberMemory();
    }
}

void bm_replay(benchmark::State& st, const char* backend_name, const std::string& trace_path) {
    const auto* trace = trace_for(trace_path);
    if (trace == nullptr) {
        st.SkipWithError("trace not loaded");
        return;
    }
    for (auto _ : st) {
        // Dataset identity was verified once at startup (see main); the
        // measured loop replays reads only, without re-hashing the file.
        auto r = dududu::parquet::replay_trace_file(backend_name, *trace,
                                                    /*verify_dataset=*/false);
        if (!r.ok()) {
            st.SkipWithError(r.status().ToString().c_str());
            return;
        }
        if (!r->ok()) {
            st.SkipWithError(r->mismatches.front().c_str());
            return;
        }
        if (st.threads() == 1) {
            st.counters["replay_bytes"] =
                benchmark::Counter(static_cast<double>(r->bytes));
            st.counters["replay_requests"] =
                benchmark::Counter(static_cast<double>(r->requests));
        }
        benchmark::DoNotOptimize(r->fnv);
        benchmark::ClobberMemory();
    }
}

} // namespace

int main(int argc, char** argv) {
    using namespace dududu::parquet;

    std::vector<char*> gb_args;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto value_of = [&](const std::string& flag) -> const char* {
            const std::string prefix = flag + "=";
            if (arg.rfind(prefix, 0) == 0) {
                return argv[i] + prefix.size();
            }
            return nullptr;
        };
        if (const char* v = value_of("--small")) {
            g_datasets.small = v;
        } else if (const char* v = value_of("--medium")) {
            g_datasets.medium = v;
        } else if (const char* v = value_of("--trace")) {
            g_datasets.trace = v;
        } else {
            gb_args.push_back(argv[i]);
        }
    }
    if (g_datasets.small.empty() && g_datasets.medium.empty()) {
        std::fprintf(stderr,
                     "parquet_bench: pass at least one of --small/--medium dataset paths\n");
        return 2;
    }
    if (!g_datasets.trace.empty() && !load_trace(g_datasets.trace)) {
        return 2;
    }

    std::vector<char*> argv_full{argv[0]};
    argv_full.insert(argv_full.end(), gb_args.begin(), gb_args.end());
    int gb_argc = static_cast<int>(argv_full.size());
    benchmark::Initialize(&gb_argc, argv_full.data());

    std::vector<std::pair<const char*, const std::string*>> datasets;
    if (!g_datasets.small.empty()) {
        datasets.push_back({"small", &g_datasets.small});
    }
    if (!g_datasets.medium.empty()) {
        datasets.push_back({"medium", &g_datasets.medium});
    }
    // Dataset identity goes into the run log so a result set can always be
    // tied to the exact bytes measured. When a trace is in play, its captured
    // dataset is verified exactly once, here — never inside the timed loop.
    for (const auto& [ds_name, ds_path] : datasets) {
        const std::string sha = dududu::parquet::sha256_file(*ds_path);
        std::printf("# dataset %s path=%s sha256=%s\n", ds_name, ds_path->c_str(),
                    sha.c_str());
        if (!g_datasets.trace.empty()) {
            const auto* trace = trace_for(g_datasets.trace);
            if (trace != nullptr && trace->dataset_path == *ds_path &&
                !trace->dataset_sha.empty() && trace->dataset_sha != sha) {
                std::fprintf(stderr,
                             "parquet_bench: dataset %s does not match the "
                             "captured trace (captured=%s actual=%s)\n",
                             ds_name, trace->dataset_sha.c_str(), sha.c_str());
                return 2;
            }
        }
    }
    const std::pair<Arm, const char*> arms[] = {
        {Arm::p0_arrow, "p0_arrow"}, {Arm::p1_native, "p1_native"},
        {Arm::p2_sluice, "p2_sluice"}};
    const std::pair<Workload, const char*> workloads[] = {
        {Workload::t1_meta, "T1_meta"},
        {Workload::t2_projection, "T2_projection"},
        {Workload::t3_full, "T3_fullscan"}};

    for (const auto& [wl_name, wl_label] : workloads) {
        for (const auto& [ds_name, ds_path] : datasets) {
            for (const auto& [arm, arm_name] : arms) {
                std::string name =
                    std::string(wl_label) + "/" + arm_name + "/" + ds_name;
                benchmark::RegisterBenchmark(name, [=](benchmark::State& st) {
                    bm_workload(st, arm, wl_name, *ds_path);
                });
            }
        }
    }
    // 4-thread full-scan variant: explores shared-file read concurrency with
    // per-iteration private handles (time-only reporting, see add_counters).
    for (const auto& [arm, arm_name] : arms) {
        if (g_datasets.medium.empty()) {
            break;
        }
        std::string name = std::string("T3_fullscan_t4/") + arm_name + "/medium";
        benchmark::RegisterBenchmark(name, [=](benchmark::State& st) {
            bm_workload(st, arm, Workload::t3_full, g_datasets.medium);
        })->Threads(4);
    }

    if (!g_datasets.trace.empty()) {
        benchmark::RegisterBenchmark("Replay/native/medium", [](benchmark::State& st) {
            bm_replay(st, "native", g_datasets.trace);
        });
        benchmark::RegisterBenchmark("Replay/sluice/medium", [](benchmark::State& st) {
            bm_replay(st, "sluice", g_datasets.trace);
        });
    }

    benchmark::RunSpecifiedBenchmarks();
    benchmark::Shutdown();
    return 0;
}

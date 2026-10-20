// Full-pipeline oracle: P0 == P1 == P2 on the real Parquet reader, plus the
// negative controls that prove the reader actually reaches each arm's backend
// and that the oracle detects wrong data.

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

#include <arrow/api.h>
#include <parquet/arrow/reader.h>
#include <parquet/exception.h>

#include "dududu/parquet/adapter_file.hpp"
#include "dududu/parquet/fixture.hpp"
#include "dududu/parquet/io_backend.hpp"
#include "dududu/parquet/io_decorators.hpp"
#include "dududu/parquet/reader_config.hpp"
#include "dududu/parquet/runner.hpp"
#include "dududu/parquet/sha256.hpp"

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
    std::string tmpl = "/tmp/dududu_parquet_oracle_XXXXXX";
    std::vector<char> buf(tmpl.begin(), tmpl.end());
    buf.push_back('\0');
    if (mkdtemp(buf.data()) == nullptr) {
        return "";
    }
    return buf.data();
}

struct RunOut {
    RunResult result;
    bool ok = false;
};

RunOut run(Arm arm, Workload wl, const std::string& path, bool verify = true) {
    RunOptions opts;
    opts.verify = verify;
    RunOut out;
    auto r = run_workload(arm, wl, path, opts);
    out.ok = r.ok();
    if (out.ok) {
        out.result = r.ValueOrDie();
    } else {
        std::fprintf(stderr, "run[%s %s] failed: %s\n", arm_name(arm),
                     workload_name(wl), r.status().ToString().c_str());
    }
    return out;
}

} // namespace

int main() {
    // SHA-256 must be anchored to the standard before anything trusts it:
    // FIPS 180-4 vectors, including the multi-update and million-'a' cases
    // that exercise partial-block buffering.
    {
        using dududu::parquet::sha256_hex;
        CHECK(sha256_hex("") ==
              "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        CHECK(sha256_hex("abc") ==
              "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        CHECK(sha256_hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
              "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
        std::string million_a(1000000, 'a');
        CHECK(sha256_hex(million_a) ==
              "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
        // Multi-update path: byte-at-a-time must equal the single-shot digest.
        dududu::parquet::Sha256 slow;
        for (char c : million_a) {
            slow.update(&c, 1);
        }
        CHECK(slow.hex_digest() ==
              "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
    }

    const std::string dir = make_temp_dir();
    if (dir.empty()) {
        std::fprintf(stderr, "oracle: temp dir failed\n");
        return 1;
    }

    auto gen = generate_fixture("small", dir, "none");
    if (!gen.ok()) {
        std::fprintf(stderr, "oracle: fixture failed: %s\n", gen.status().ToString().c_str());
        return 1;
    }
    const std::string path = gen.ValueOrDie().path;

    // --- T3 full scan: three arms, one oracle --------------------------------
    RunOut p0 = run(Arm::p0_arrow, Workload::t3_full, path);
    RunOut p1 = run(Arm::p1_native, Workload::t3_full, path);
    RunOut p2 = run(Arm::p2_sluice, Workload::t3_full, path);
    CHECK(p0.ok && p1.ok && p2.ok);
    if (p0.ok && p1.ok && p2.ok) {
        CHECK(p0.result.oracle.combined() == p1.result.oracle.combined());
        CHECK(p0.result.oracle.combined() == p2.result.oracle.combined());
        CHECK(p0.result.rows == 40000);
        CHECK(p0.result.row_groups == 6);
        CHECK(p0.result.oracle.null_counts.size() == 7);
        // Decoded cells: rows * columns
        CHECK(p0.result.decoded_cells == 40000 * 7);
        std::printf("oracle t3: data_sha=%s\n", p0.result.oracle.data_sha.c_str());
    }

    // --- T2 projection: same value-digest rule over the projected columns ----
    RunOut q0 = run(Arm::p0_arrow, Workload::t2_projection, path);
    RunOut q1 = run(Arm::p1_native, Workload::t2_projection, path);
    RunOut q2 = run(Arm::p2_sluice, Workload::t2_projection, path);
    CHECK(q0.ok && q1.ok && q2.ok);
    if (q0.ok && q1.ok && q2.ok) {
        CHECK(q0.result.oracle.combined() == q1.result.oracle.combined());
        CHECK(q0.result.oracle.combined() == q2.result.oracle.combined());
        CHECK(q0.result.columns_read == 2);
        // Projection must prune reads: projected bytes strictly below a full
        // scan's requested bytes (the wide column alone is most of the file).
        CHECK(q1.result.counters.requested_bytes < p1.result.counters.requested_bytes);
        CHECK(q2.result.counters.requested_bytes < p2.result.counters.requested_bytes);
    }

    // --- T1 metadata: identical skeleton across arms --------------------------
    RunOut m0 = run(Arm::p0_arrow, Workload::t1_meta, path);
    RunOut m1 = run(Arm::p1_native, Workload::t1_meta, path);
    RunOut m2 = run(Arm::p2_sluice, Workload::t1_meta, path);
    CHECK(m0.ok && m1.ok && m2.ok);
    if (m0.ok && m1.ok && m2.ok) {
        CHECK(m0.result.metadata.digest == m1.result.metadata.digest);
        CHECK(m0.result.metadata.digest == m2.result.metadata.digest);
        CHECK(m0.result.metadata.num_rows == 40000);
        CHECK(m0.result.metadata.num_row_groups == 6);
    }

    // --- negative control: P1 backend fault reaches the reader ----------------
    {
        // Mid-data read index taken from the clean P1 run just above.
        const int64_t mid =
            static_cast<int64_t>(p1.result.counters.read_at_calls / 2);
        CHECK(mid > 0);

        auto counting = std::make_unique<CountingBackend>(make_backend(Arm::p1_native));
        auto* counts = counting.get();
        auto fault = std::make_unique<FaultInjectionBackend>(std::move(counting));
        auto* fault_ptr = fault.get();
        fault_ptr->fail_read_at_at(mid, arrow::StatusCode::IOError, "native read refused");

        auto faulted = AdapterFile::open(std::move(fault), path);
        CHECK(faulted.ok());
        parquet::arrow::FileReaderBuilder builder;
        CHECK(builder.Open(faulted.ValueOrDie()).ok());
        // The experiment's frozen reader configuration is exactly the path
        // under test: the injection must break it there, not in some other
        // configuration.
        configure_reader(builder);
        auto reader_res = builder.Build();
        CHECK(reader_res.ok());
        std::shared_ptr<arrow::Table> table;
        // The reader must surface the injected failure, never a fake success.
        auto st = reader_res.ValueOrDie()->ReadTable(&table);
        CHECK(!st.ok());
        std::fprintf(stderr,
                     "p1 fault diag: mid=%lld fault_calls=%lld counted=%lld st=%.60s\n",
                     static_cast<long long>(mid),
                     static_cast<long long>(fault_ptr->read_at_calls()),
                     static_cast<long long>(counts->counters().read_at_calls),
                     st.ToString().c_str());
        CHECK(fault_ptr->read_at_calls() == mid + 1); // reached, refused, stopped
        CHECK(counts->counters().read_at_calls == mid); // fault fired before counting
        static_cast<void>(faulted.ValueOrDie()->Close());
    }

    // --- negative control: P2 fault + no-sluice-read-at-all -------------------
    for (bool fail_all : {false, true}) {
        auto fault = std::make_unique<FaultInjectionBackend>(make_backend(Arm::p2_sluice));
        auto* fault_ptr = fault.get();
        if (fail_all) {
            fault_ptr->fail_every_read(arrow::StatusCode::IOError, "no sluice read allowed");
        } else {
            // Footer read (#0) succeeds, an early data read dies mid-flight.
            fault_ptr->fail_read_at_at(4, arrow::StatusCode::IOError, "sluice read refused");
        }
        auto f = AdapterFile::open(std::move(fault), path);
        CHECK(f.ok());
        parquet::arrow::FileReaderBuilder builder;
        arrow::Status st = builder.Open(f.ValueOrDie());
        std::shared_ptr<arrow::Table> table;
        if (st.ok()) {
            configure_reader(builder);
            auto reader_res = builder.Build();
            if (reader_res.ok()) {
                st = reader_res.ValueOrDie()->ReadTable(&table);
            } else {
                st = reader_res.status();
            }
        }
        CHECK(!st.ok());
        if (fail_all) {
            CHECK(fault_ptr->read_at_calls() == 1); // footer read refused, no fallback
        } else {
            CHECK(fault_ptr->read_at_calls() == 5);
        }
        static_cast<void>(f.ValueOrDie()->Close());
        std::fprintf(stderr, "negative p2(fail_all=%d): reader error: %.80s...\n",
                     fail_all ? 1 : 0, st.ToString().c_str());
    }

    // --- negative control: oracle rejects a fake backend ----------------------
    {
        // A "backend" that claims success and moves no bytes. If the oracle
        // or the reader accepted its output, nothing we measured would be
        // worth anything: the footer read must fail.
        auto fake = std::make_unique<FakeZeroBackend>();
        fake->set_size(gen.ValueOrDie().bytes);
        auto f = AdapterFile::open(std::move(fake), path);
        CHECK(f.ok());
        parquet::arrow::FileReaderBuilder builder;
        auto st = builder.Open(f.ValueOrDie());
        CHECK(!st.ok()); // zero bytes delivered can never yield a footer
        static_cast<void>(f.ValueOrDie()->Close());
    }

    // --- negative control: corrupted data byte -------------------------------
    {
        const std::string corrupt = dir + "/corrupt.parquet";
        {
            FILE* in = std::fopen(path.c_str(), "rb");
            FILE* out = std::fopen(corrupt.c_str(), "wb");
            CHECK(in != nullptr && out != nullptr);
            char buf[65536];
            size_t n;
            while ((n = std::fread(buf, 1, sizeof(buf), in)) > 0) {
                std::fwrite(buf, 1, n, out);
            }
            std::fclose(in);
            std::fclose(out);
        }
        // Flip one byte deep inside the first data page region (well past the
        // header, well before the footer).
        const int64_t flip_at = 20000;
        FILE* f = std::fopen(corrupt.c_str(), "r+b");
        CHECK(f != nullptr);
        std::fseek(f, flip_at, SEEK_SET);
        int c = std::fgetc(f);
        std::fseek(f, flip_at, SEEK_SET);
        std::fputc(c ^ 0xff, f);
        std::fclose(f);

        RunOut bad = run(Arm::p0_arrow, Workload::t3_full, corrupt);
        if (bad.ok) {
            // No page checksums are configured, so the decode may succeed —
            // then the oracle MUST see different values. Both outcomes are
            // acceptable only through one of these two evidences.
            CHECK(bad.result.oracle.combined() != p0.result.oracle.combined());
        }
    }

    // --- negative control: truncated footer -----------------------------------
    {
        const std::string trunc = dir + "/truncated.parquet";
        {
            FILE* in = std::fopen(path.c_str(), "rb");
            FILE* out = std::fopen(trunc.c_str(), "wb");
            CHECK(in != nullptr && out != nullptr);
            char buf[65536];
            size_t n;
            int64_t total = 0;
            const int64_t keep = gen.ValueOrDie().bytes - 64;
            while (total < keep && (n = std::fread(buf, 1, sizeof(buf), in)) > 0) {
                const int64_t take =
                    std::min<int64_t>(static_cast<int64_t>(n), keep - total);
                std::fwrite(buf, 1, static_cast<std::size_t>(take), out);
                total += take;
            }
            std::fclose(in);
            std::fclose(out);
        }
        for (Arm arm : {Arm::p0_arrow, Arm::p1_native, Arm::p2_sluice}) {
            RunOut bad = run(arm, Workload::t1_meta, trunc);
            CHECK(!bad.ok); // a truncated footer must never open cleanly
        }
    }

    // --- concurrency through the real reader (per-thread handles) -------------
    {
        constexpr int kThreads = 4;
        std::vector<std::string> digests(static_cast<std::size_t>(kThreads));
        std::vector<std::thread> threads;
        for (int t = 0; t < kThreads; ++t) {
            threads.emplace_back([&, t] {
                Arm arm = t % 2 == 0 ? Arm::p1_native : Arm::p2_sluice;
                auto r = run_workload(arm, Workload::t3_full, path, RunOptions{true});
                if (r.ok()) {
                    digests[static_cast<std::size_t>(t)] =
                        r.ValueOrDie().oracle.combined();
                } else {
                    std::fprintf(stderr, "concurrent run failed: %s\n",
                                 r.status().ToString().c_str());
                }
            });
        }
        for (auto& th : threads) {
            th.join();
        }
        for (const auto& d : digests) {
            CHECK(d == p0.result.oracle.combined());
        }
    }

    if (failures != 0) {
        std::fprintf(stderr, "parquet_oracle_test: %d failure(s)\n", failures);
        return 1;
    }
    std::printf("parquet_oracle_test: PASS\n");
    return 0;
}

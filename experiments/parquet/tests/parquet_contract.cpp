// Adapter-level contract tests for the P1/P2 read backends and AdapterFile.
// No Parquet involved: the byte layer itself must obey the documented
// contract on both arms, identically.

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <vector>

#include <arrow/buffer.h>

#include "dududu/parquet/adapter_file.hpp"
#include "dududu/parquet/io_backend.hpp"

using dududu::parquet::AdapterFile;
using dududu::parquet::Arm;

namespace {

int failures = 0;

#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            ++failures;                                                          \
        }                                                                        \
    } while (0)

const char* arm_str(Arm a) { return a == Arm::p1_native ? "p1" : "p2"; }

// Deterministic 1 MiB pattern file: byte i is (i * 131 + (i >> 12)) & 0xff.
std::string write_pattern_file(const std::string& path, int64_t bytes) {
    FILE* f = std::fopen(path.c_str(), "wb");
    if (f == nullptr) {
        return "";
    }
    std::vector<uint8_t> buf(65536);
    for (int64_t off = 0; off < bytes; off += static_cast<int64_t>(buf.size())) {
        for (std::size_t i = 0; i < buf.size(); ++i) {
            const int64_t pos = off + static_cast<int64_t>(i);
            buf[i] = static_cast<uint8_t>((pos * 131 + (pos >> 12)) & 0xff);
        }
        const int64_t take =
            std::min<int64_t>(static_cast<int64_t>(buf.size()), bytes - off);
        std::fwrite(buf.data(), 1, static_cast<std::size_t>(take), f);
    }
    std::fclose(f);
    return path;
}

uint8_t expected_byte(int64_t pos) {
    return static_cast<uint8_t>((pos * 131 + (pos >> 12)) & 0xff);
}

void run_arm_contract(Arm arm, const std::string& path, int64_t file_size) {
    std::fprintf(stderr, "contract[%s]\n", arm_str(arm));

    // --- open ---------------------------------------------------------------
    auto opened = AdapterFile::open(arm, "/nonexistent/definitely-missing");
    CHECK(!opened.ok());

    opened = AdapterFile::open(arm, path);
    CHECK(opened.ok());
    if (!opened.ok()) {
        return;
    }
    std::shared_ptr<AdapterFile> file = opened.ValueOrDie();

    // --- size ---------------------------------------------------------------
    CHECK(file->GetSize().ValueOrDie() == file_size);
    CHECK(file->Tell().ValueOrDie() == 0);

    // --- ReadAt: full, short, EOF, past-EOF ----------------------------------
    std::vector<uint8_t> buf(4096);
    auto r = file->ReadAt(0, static_cast<int64_t>(buf.size()), buf.data());
    CHECK(r.ok() && r.ValueOrDie() == static_cast<int64_t>(buf.size()));
    for (int i = 0; i < 16; ++i) {
        CHECK(buf[static_cast<std::size_t>(i)] == expected_byte(i));
    }

    const int64_t tail_off = file_size - 100;
    r = file->ReadAt(tail_off, 4096, buf.data());
    CHECK(r.ok() && r.ValueOrDie() == 100); // short read at EOF
    for (int i = 0; i < 100; ++i) {
        CHECK(buf[static_cast<std::size_t>(i)] == expected_byte(tail_off + i));
    }

    r = file->ReadAt(file_size, 16, buf.data());
    CHECK(r.ok() && r.ValueOrDie() == 0); // EOF is a zero-byte success

    r = file->ReadAt(file_size + 4096, 16, buf.data());
    CHECK(r.ok() && r.ValueOrDie() == 0); // past EOF too

    r = file->ReadAt(123, 0, buf.data());
    CHECK(r.ok() && r.ValueOrDie() == 0); // empty request is not an error

    // Buffer variant
    auto br = file->ReadAt(4096, 1024);
    CHECK(br.ok() && br.ValueOrDie()->size() == 1024);
    for (int i = 0; i < 16; ++i) {
        CHECK(br.ValueOrDie()->data()[i] == expected_byte(4096 + i));
    }

    // --- invalid arguments: rejected before I/O, on both arms ---------------
    CHECK(!file->ReadAt(-1, 16, buf.data()).ok());
    CHECK(!file->ReadAt(0, -16, buf.data()).ok());
    CHECK(!file->ReadAt(1LL << 62, (1LL << 62) + 4, buf.data()).ok());
    CHECK(!file->Seek(-1).ok());
    CHECK(!file->Read(-4, buf.data()).ok());

    // ReadAt must not move the cursor (contract: position unspecified, ours:
    // untouched).
    CHECK(file->Tell().ValueOrDie() == 0);

    // --- cursor family -------------------------------------------------------
    CHECK(file->Seek(1000).ok());
    CHECK(file->Tell().ValueOrDie() == 1000);
    r = file->Read(64, buf.data());
    CHECK(r.ok() && r.ValueOrDie() == 64);
    CHECK(file->Tell().ValueOrDie() == 1064);
    for (int i = 0; i < 16; ++i) {
        CHECK(buf[static_cast<std::size_t>(i)] == expected_byte(1000 + i));
    }

    CHECK(file->Seek(static_cast<int64_t>(file_size) - 10).ok());
    r = file->Read(64, buf.data());
    CHECK(r.ok() && r.ValueOrDie() == 10); // cursor short read at EOF
    CHECK(file->Tell().ValueOrDie() == file_size);

    auto sr = file->Read(32); // cursor buffer read at EOF: empty buffer
    CHECK(sr.ok() && sr.ValueOrDie()->size() == 0);

    // --- concurrent positional reads ----------------------------------------
    // The RandomAccessFile contract allows concurrent ReadAt; verify results
    // stay exact under interleaving.
    {
        constexpr int kThreads = 4;
        constexpr int kPerThread = 200;
        std::vector<std::thread> threads;
        std::atomic<int> bad{0};
        for (int t = 0; t < kThreads; ++t) {
            threads.emplace_back([&, t] {
                std::vector<uint8_t> local(512);
                for (int i = 0; i < kPerThread; ++i) {
                    const int64_t off =
                        (static_cast<int64_t>(t) * 977 + i * 7919) % (file_size - 512);
                    auto rr = file->ReadAt(off, 512, local.data());
                    if (!rr.ok() || rr.ValueOrDie() != 512) {
                        ++bad;
                        continue;
                    }
                    for (int64_t b = 0; b < 512; ++b) {
                        if (local[static_cast<std::size_t>(b)] !=
                            expected_byte(off + b)) {
                            ++bad;
                            break;
                        }
                    }
                }
            });
        }
        for (auto& th : threads) {
            th.join();
        }
        CHECK(bad.load() == 0);
    }

    // --- close semantics -----------------------------------------------------
    CHECK(file->Close().ok());
    CHECK(file->closed());
    CHECK(!file->ReadAt(0, 16, buf.data()).ok());     // closed reads fail
    CHECK(!file->GetSize().ok());
    CHECK(!file->Read(4, buf.data()).ok());
    CHECK(file->Close().ok());                        // double close is fine
    CHECK(file->closed());
    file.reset();                                     // destructor after close

    // --- destructor without explicit close ------------------------------------
    {
        auto f2 = AdapterFile::open(arm, path);
        CHECK(f2.ok());
        f2.ValueOrDie().reset(); // RAII close
    }
}

} // namespace

int main() {
    std::string tmpl = "/tmp/dududu_parquet_contract_XXXXXX";
    std::vector<char> dirbuf(tmpl.begin(), tmpl.end());
    dirbuf.push_back('\0');
    if (mkdtemp(dirbuf.data()) == nullptr) {
        std::fprintf(stderr, "contract: temp dir failed\n");
        return 1;
    }
    const std::string workdir = dirbuf.data();
    const std::string path = workdir + "/pattern.bin";
    const int64_t kSize = 1 << 20;
    if (write_pattern_file(path, kSize).empty()) {
        std::fprintf(stderr, "contract: pattern file write failed\n");
        return 1;
    }

    run_arm_contract(Arm::p1_native, path, kSize);
    run_arm_contract(Arm::p2_sluice, path, kSize);

    // Parity: identical probe results on both arms across an offset grid
    // that includes EOF boundaries.
    {
        auto f1 = AdapterFile::open(Arm::p1_native, path);
        auto f2 = AdapterFile::open(Arm::p2_sluice, path);
        CHECK(f1.ok() && f2.ok());
        auto a = f1.ValueOrDie();
        auto b = f2.ValueOrDie();
        std::vector<uint8_t> ba(4096), bb(4096);
        const int64_t offs[] = {0, 1, 4095, 4096, kSize - 1, kSize, kSize + 123};
        const int64_t lens[] = {0, 1, 100, 4096};
        for (int64_t off : offs) {
            for (int64_t len : lens) {
                auto ra = a->ReadAt(off, len, ba.data());
                auto rb = b->ReadAt(off, len, bb.data());
                if (!ra.ok() || !rb.ok()) {
                    CHECK(false);
                    continue;
                }
                CHECK(ra.ValueOrDie() == rb.ValueOrDie());
                CHECK(std::memcmp(ba.data(), bb.data(),
                                  static_cast<std::size_t>(ra.ValueOrDie())) == 0);
            }
        }
    }

    if (failures != 0) {
        std::fprintf(stderr, "parquet_contract_test: %d failure(s)\n", failures);
        return 1;
    }
    std::printf("parquet_contract_test: PASS\n");
    return 0;
}

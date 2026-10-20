// dududu SDK consumer smoke (W-01 direct).
//
// Built and linked against the *installed* Sluice prefix only (header include
// path and libsluice_core.a), never against the submodule source tree. This is
// the core-only boundary probe: no async header, no async archive.
#include <sluice/blocking/file.hpp>
#include <sluice/file_resource.hpp>

#include <cstddef>
#include <cstdio>
#include <string>
#include <utility>
#include <vector>

#include <unistd.h>

namespace {

int failures = 0;

#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            ++failures;                                                          \
        }                                                                        \
    } while (0)

std::string make_temp_path() {
    char path[] = "/tmp/dududu_core_XXXXXX";
    const int fd = ::mkstemp(path);
    if (fd < 0)
        return {};
    ::close(fd);
    return path;
}

sluice::FileOpen create_read_write() {
    sluice::FileOpen mode;
    mode.access = sluice::FileAccess::read_write;
    mode.existence = sluice::FileExistence::create_if_missing;
    return mode;
}

} // namespace

int main() {
    using sluice::File;
    using sluice::FileKind;

    const std::string path = make_temp_path();
    if (path.empty()) {
        std::fprintf(stderr, "core_consumer: mkstemp failed\n");
        return 1;
    }

    auto opened = File::open(path, create_read_write());
    CHECK(opened.has_value());
    if (!opened.has_value()) {
        ::unlink(path.c_str());
        return 1;
    }
    File file = std::move(opened).value();

    auto info = sluice::blocking::file_info(file);
    CHECK(info.has_value());
    CHECK(info.value().kind == FileKind::regular);
    CHECK(info.value().size == 0);
    CHECK(info.value().identity.has_value());

    const std::string payload = "dududu-sluice-sdk";
    const std::span<const std::byte> bytes(
        reinterpret_cast<const std::byte*>(payload.data()), payload.size());
    auto wrote = sluice::blocking::write_at(file, 0, bytes);
    CHECK(wrote.has_value() && wrote.value() == payload.size());
    CHECK(sluice::blocking::sync_data(file).has_value());

    std::vector<std::byte> out(payload.size(), std::byte{0});
    auto read = sluice::blocking::read_exact(file, out);
    CHECK(read.has_value() && read.value().complete());
    CHECK(std::string(reinterpret_cast<const char*>(out.data()), out.size()) == payload);

    // Short read across EOF: offset 3 with a buffer larger than the remainder.
    std::vector<std::byte> past_eof(payload.size() + 32, std::byte{0});
    auto short_read = sluice::blocking::read_at(file, 3, past_eof);
    CHECK(short_read.has_value());
    CHECK(short_read.value() == payload.size() - 3);

    CHECK(file.close().has_value());
    CHECK(!file.is_open());
    ::unlink(path.c_str());

    if (failures != 0) {
        std::fprintf(stderr, "core_consumer: %d failure(s)\n", failures);
        return 1;
    }
    std::printf("core_consumer: PASS\n");
    return 0;
}

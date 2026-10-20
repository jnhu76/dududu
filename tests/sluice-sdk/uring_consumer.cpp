// dududu SDK consumer smoke (W-03 external loop, io_uring profile).
//
// Built against the liburing=y installed prefix. Exit code contract:
//   0  request round-trip completed through the public context
//   1  functional failure
//   2  io_uring unavailable in this environment (NOT_SUPPORTED, not a PASS)
//
// CTest maps exit 2 to SKIP_RETURN_CODE so an environment without io_uring is
// reported as skipped rather than green.
#include <sluice/async/uring_backend.hpp>
#include <sluice/blocking/file.hpp>
#include <sluice/file_resource.hpp>

#include <chrono>
#include <cstddef>
#include <cstdio>
#include <exception>
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
    char path[] = "/tmp/dududu_uring_XXXXXX";
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
    using namespace sluice;
    using namespace sluice::async;

    sluice::async::AsyncIoContext ctx = [&]() -> sluice::async::AsyncIoContext {
        try {
            auto selected =
                make_uring_context(UringConfig{.request_capacity = 8, .queue_depth = 64});
            if (selected.has_value())
                return std::move(selected).value();
            std::printf("uring_consumer: NOT_SUPPORTED (%s)\n",
                        std::string(to_string(selected.error().code)).c_str());
        } catch (const std::exception& error) {
            std::printf("uring_consumer: NOT_SUPPORTED (ring setup threw: %s)\n", error.what());
        }
        std::exit(2);
    }();

    const std::string path = make_temp_path();
    if (path.empty()) {
        std::fprintf(stderr, "uring_consumer: mkstemp failed\n");
        return 1;
    }

    auto opened = File::open(path, create_read_write());
    CHECK(opened.has_value());
    if (!opened.has_value()) {
        ::unlink(path.c_str());
        return 1;
    }
    File file = std::move(opened).value();

    const std::string payload = "0123456789abcdef";
    const std::span<const std::byte> bytes(
        reinterpret_cast<const std::byte*>(payload.data()), payload.size());
    CHECK(sluice::blocking::write_all(file, bytes).has_value());

    std::vector<std::byte> buf(8, std::byte{0});
    auto submitted = ctx.submit_read(
        ReadOp{.file = NativeFileRef{file}, .dst = buf.data(), .len = buf.size(), .offset = 4});
    CHECK(submitted.has_value());

    if (submitted.has_value()) {
        Request<std::size_t> request = std::move(submitted).value();
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        while (!request.ready() && std::chrono::steady_clock::now() < deadline) {
            const auto pass = ctx.poll();
            if (!pass.has_value()) {
                std::fprintf(stderr, "uring_consumer: poll failed: %s\n",
                             std::string(to_string(pass.error().code)).c_str());
                ++failures;
                break;
            }
        }
        CHECK(request.ready());
        if (request.ready()) {
            auto observed = request.take_result();
            CHECK(observed.readiness == RequestReadiness::ready);
            CHECK(observed.result.has_value());
            CHECK(observed.result.has_value() && observed.result.value() == buf.size());
            CHECK(std::string(reinterpret_cast<const char*>(buf.data()), buf.size()) == "456789ab");
        }
    }

    CHECK(ctx.shutdown(ShutdownPolicy::drain).has_value());
    CHECK(file.close().has_value());
    ::unlink(path.c_str());

    if (failures != 0) {
        std::fprintf(stderr, "uring_consumer: %d failure(s)\n", failures);
        return 1;
    }
    std::printf("uring_consumer: PASS\n");
    return 0;
}

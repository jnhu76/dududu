// dududu SDK consumer smoke (W-02 bounded pipeline, ThreadPool backend).
//
// Consumes the installed prefix only: async + core archives, no backend class,
// no detail header, no build-profile macro.
#include <sluice/async/request_scope.hpp>
#include <sluice/async/threadpool_backend.hpp>
#include <sluice/blocking/file.hpp>
#include <sluice/file_resource.hpp>

#include <chrono>
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
    char path[] = "/tmp/dududu_threadpool_XXXXXX";
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

    const std::string path = make_temp_path();
    if (path.empty()) {
        std::fprintf(stderr, "threadpool_consumer: mkstemp failed\n");
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

    AsyncIoContext ctx = make_threadpool_context(
        ThreadPoolConfig{.request_capacity = 8, .worker_count = 2});
    RequestScope scope(ctx, 4, ScopeCleanupPolicy::drain);

    std::vector<std::byte> first(4, std::byte{0});
    std::vector<std::byte> second(4, std::byte{0});

    auto a = scope.submit_read(
        ReadOp{.file = NativeFileRef{file}, .dst = first.data(), .len = first.size(), .offset = 0});
    auto b = scope.submit_read(ReadOp{
        .file = NativeFileRef{file}, .dst = second.data(), .len = second.size(), .offset = 8});
    CHECK(a.has_value() && b.has_value());

    if (a.has_value() && b.has_value()) {
        CHECK(scope.wait_for(a.value(), std::chrono::seconds(5)).has_value());
        CHECK(scope.wait_for(b.value(), std::chrono::seconds(5)).has_value());

        const auto ra = scope.take(a.value());
        const auto rb = scope.take(b.value());
        CHECK(ra.readiness == RequestReadiness::ready && ra.result.has_value());
        CHECK(rb.readiness == RequestReadiness::ready && rb.result.has_value());
        CHECK(ra.result.has_value() && ra.result.value() == 4);
        CHECK(rb.result.has_value() && rb.result.value() == 4);
        CHECK(std::string(reinterpret_cast<const char*>(first.data()), 4) == "0123");
        CHECK(std::string(reinterpret_cast<const char*>(second.data()), 4) == "89ab");
    }

    CHECK(scope.finish().has_value());
    CHECK(ctx.shutdown(ShutdownPolicy::drain).has_value());
    CHECK(file.close().has_value());
    ::unlink(path.c_str());

    if (failures != 0) {
        std::fprintf(stderr, "threadpool_consumer: %d failure(s)\n", failures);
        return 1;
    }
    std::printf("threadpool_consumer: PASS\n");
    return 0;
}

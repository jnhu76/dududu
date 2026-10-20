// dududu SDK consumer smoke (absence contract).
//
// Built against the liburing=n installed prefix. The contract under test is
// that selecting io_uring there is an *explicit* not_supported result, not a
// silent fallback to another execution. Exit 0 means the absence contract
// held; exit 1 means the noliburing package silently produced an io_uring
// context or reported a different error class.
#include <sluice/async/uring_backend.hpp>

#include <cstdio>
#include <exception>
#include <string>

int main() {
    using namespace sluice;
    using namespace sluice::async;

    try {
        auto selected =
            make_uring_context(UringConfig{.request_capacity = 8, .queue_depth = 64});
        if (selected.has_value()) {
            std::printf("uring_absence_consumer: FAIL (context created in a noliburing build)\n");
            return 1;
        }
        if (selected.error().code != IoError::Code::not_supported) {
            std::printf("uring_absence_consumer: FAIL (error=%s, expected not_supported)\n",
                        std::string(to_string(selected.error().code)).c_str());
            return 1;
        }
        std::printf("uring_absence_consumer: PASS (explicit not_supported)\n");
        return 0;
    } catch (const std::exception& error) {
        std::printf("uring_absence_consumer: FAIL (threw instead of returning not_supported: %s)\n",
                    error.what());
        return 1;
    }
}

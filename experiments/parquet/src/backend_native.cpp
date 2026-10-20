#include <arrow/status.h>

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

#include "dududu/parquet/io_backend.hpp"

namespace dududu::parquet {
namespace {

// Canonical error names shared with the Sluice backend so that P1 and P2
// report the same vocabulary for the same failure. The mapping mirrors
// Sluice's detail::canonical_error_code on purpose (io error.hpp); it is
// re-declared here instead of imported so that this TU keeps no dependency
// on Sluice headers — the native arm must be buildable without them.
const char* errno_name(int err) {
    switch (err) {
    case EACCES:
    case EPERM: return "permission_denied";
    case ENOENT:
    case ENOTDIR: return "not_found";
    case ENOSPC:
#ifdef EDQUOT
    case EDQUOT:
#endif
        return "no_space";
    case EINTR: return "interrupted";
    case EAGAIN:
#if defined(EWOULDBLOCK) && EWOULDBLOCK != EAGAIN
    case EWOULDBLOCK:
#endif
        return "would_block";
    case EINVAL: return "invalid_argument";
    case EISDIR: return "not_regular_file";
    default: return "backend_error";
    }
}

arrow::Status errno_status(const char* op, const std::string& path, const char* backend) {
    const int err = errno;
    std::string msg = std::string(backend) + " " + op + " failed: " + errno_name(err) +
                      " (errno=" + std::to_string(err) + " " + std::strerror(err) + ")" +
                      " path=" + path;
    if (err == EINVAL) {
        return arrow::Status::Invalid(msg);
    }
    return arrow::Status::IOError(msg);
}

// P1's byte-moving primitive. A short read is data (EOF), not an error, and
// is returned as-is; only EINTR is retried, exactly like Sluice's
// retry_on_eintr, so a transient signal costs the same on both arms.
arrow::Result<int64_t> pread_primitive(int fd, int64_t offset, int64_t nbytes, void* out,
                                       const std::string& path) {
    ssize_t n;
    do {
        n = ::pread(fd, out, static_cast<size_t>(nbytes), static_cast<off_t>(offset));
    } while (n < 0 && errno == EINTR);
    if (n < 0) {
        return errno_status("pread", path, "p1-native");
    }
    return static_cast<int64_t>(n);
}

class NativePosixBackend final : public IoBackend {
  public:
    ~NativePosixBackend() override { static_cast<void>(close()); }

    arrow::Status open(const std::string& path) override {
        if (!closed_) {
            return arrow::Status::Invalid("p1-native: already open: ", path);
        }
        const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
        if (fd < 0) {
            return errno_status("open", path, "p1-native");
        }
        struct stat st {};
        if (::fstat(fd, &st) != 0) {
            const int err = errno;
            ::close(fd);
            errno = err;
            return errno_status("fstat", path, "p1-native");
        }
        if (!S_ISREG(st.st_mode)) {
            ::close(fd);
            return arrow::Status::Invalid("p1-native: not a regular file: ", path);
        }
        fd_ = fd;
        size_ = static_cast<int64_t>(st.st_size);
        path_ = path;
        closed_ = false;
        return arrow::Status::OK();
    }

    arrow::Result<int64_t> size() override {
        if (closed_) {
            return arrow::Status::Invalid("p1-native: size on closed file");
        }
        return size_;
    }

    arrow::Result<int64_t> read_at(int64_t offset, int64_t nbytes, void* out) override {
        if (auto st = validate_read_args(offset, nbytes); !st.ok()) {
            return st;
        }
        if (closed_) {
            return arrow::Status::Invalid("p1-native: read_at on closed file");
        }
        if (nbytes == 0) {
            return int64_t{0};
        }
        return pread_primitive(fd_, offset, nbytes, out, path_);
    }

    arrow::Status close() override {
        if (closed_ && fd_ < 0) {
            return arrow::Status::OK();
        }
        closed_ = true;
        const int fd = fd_;
        fd_ = -1;
        if (::close(fd) != 0) {
            return errno_status("close", path_, "p1-native");
        }
        return arrow::Status::OK();
    }

    bool closed() const override { return closed_; }
    const char* name() const override { return "p1-native"; }

  private:
    int fd_ = -1;
    int64_t size_ = -1;
    std::string path_;
    bool closed_ = true;
};

} // namespace

arrow::Status validate_read_args(int64_t offset, int64_t nbytes) {
    if (offset < 0) {
        return arrow::Status::Invalid("negative read offset: ", std::to_string(offset));
    }
    if (nbytes < 0) {
        return arrow::Status::Invalid("negative read length: ", std::to_string(nbytes));
    }
    if (offset > std::numeric_limits<int64_t>::max() - nbytes) {
        return arrow::Status::Invalid("read range overflows the address space: offset=",
                                      std::to_string(offset), " length=", std::to_string(nbytes));
    }
    return arrow::Status::OK();
}

const char* arm_name(Arm arm) {
    switch (arm) {
    case Arm::p0_arrow: return "p0-arrow";
    case Arm::p1_native: return "p1-native";
    case Arm::p2_sluice: return "p2-sluice";
    }
    return "unknown";
}

std::unique_ptr<IoBackend> make_native_backend() {
    return std::make_unique<NativePosixBackend>();
}

} // namespace dududu::parquet

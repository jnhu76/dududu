#include <sluice/blocking/file.hpp>
#include <sluice/error.hpp>
#include <sluice/file_resource.hpp>

#include <arrow/status.h>

#include <cerrno>
#include <cstring>
#include <limits>
#include <optional>
#include <string>

#include "dududu/parquet/io_backend.hpp"

namespace dududu::parquet {
namespace {

// P2's only error path: the original Sluice code and os_errno are preserved
// verbatim in the message as diagnostic evidence. Legal EOF never reaches
// this function — read_at reports EOF as a zero-byte success.
arrow::Status sluice_error_status(const sluice::IoError& e, const char* op) {
    std::string msg = std::string("p2-sluice ") + op + " failed: " +
                      std::string(sluice::to_string(e.code));
    if (e.os_errno != 0) {
        msg += " (os_errno=" + std::to_string(e.os_errno) + " " + std::strerror(e.os_errno) + ")";
    }
    switch (e.code) {
    case sluice::IoError::Code::invalid_argument:
        return arrow::Status::Invalid(msg);
    case sluice::IoError::Code::not_supported:
        return arrow::Status::NotImplemented(msg);
    default:
        return arrow::Status::IOError(msg);
    }
}

sluice::FileOpen read_only_existing() {
    sluice::FileOpen mode;
    mode.access = sluice::FileAccess::read_only;
    mode.existence = sluice::FileExistence::open_existing;
    mode.contents = sluice::FileInitialContents::preserve;
    return mode;
}

// P2's byte-moving primitive is sluice::blocking::read_at: short reads are
// data (EOF at 0), errors come back as IoError, and the fd is only borrowed
// from the File owner. This TU contains no pread/read call of its own.
class SluiceDirectBackend final : public IoBackend {
  public:
    ~SluiceDirectBackend() override { static_cast<void>(close()); }

    arrow::Status open(const std::string& path) override {
        if (!closed_) {
            return arrow::Status::Invalid("p2-sluice: already open: ", path);
        }
        auto opened = sluice::File::open(path, read_only_existing());
        if (!opened.has_value()) {
            return sluice_error_status(opened.error(), "open");
        }
        file_.emplace(std::move(opened).value());
        closed_ = false;
        return arrow::Status::OK();
    }

    arrow::Result<int64_t> size() override {
        if (closed_ || !file_.has_value()) {
            return arrow::Status::Invalid("p2-sluice: size on closed file");
        }
        auto sz = sluice::blocking::size(*file_);
        if (!sz.has_value()) {
            return sluice_error_status(sz.error(), "size");
        }
        if (sz.value() > static_cast<std::uint64_t>(std::numeric_limits<int64_t>::max())) {
            return arrow::Status::Invalid("p2-sluice: file exceeds int64 size");
        }
        return static_cast<int64_t>(sz.value());
    }

    arrow::Result<int64_t> read_at(int64_t offset, int64_t nbytes, void* out) override {
        if (auto st = validate_read_args(offset, nbytes); !st.ok()) {
            return st;
        }
        if (closed_ || !file_.has_value()) {
            return arrow::Status::Invalid("p2-sluice: read_at on closed file");
        }
        if (nbytes == 0) {
            return int64_t{0};
        }
        const std::span<std::byte> dst(static_cast<std::byte*>(out),
                                       static_cast<std::size_t>(nbytes));
        auto r = sluice::blocking::read_at(*file_, static_cast<std::uint64_t>(offset), dst);
        if (!r.has_value()) {
            return sluice_error_status(r.error(), "read_at");
        }
        return static_cast<int64_t>(r.value());
    }

    arrow::Status close() override {
        if (closed_ && !file_.has_value()) {
            return arrow::Status::OK();
        }
        closed_ = true;
        if (file_.has_value()) {
            // Explicit close keeps a close error visible; the destructor would
            // only release the descriptor silently.
            auto rc = file_->close();
            file_.reset();
            if (!rc.has_value()) {
                return sluice_error_status(rc.error(), "close");
            }
        }
        return arrow::Status::OK();
    }

    bool closed() const override { return closed_; }
    const char* name() const override { return "p2-sluice"; }

  private:
    std::optional<sluice::File> file_;
    bool closed_ = true;
};

} // namespace

std::unique_ptr<IoBackend> make_sluice_backend() {
    return std::make_unique<SluiceDirectBackend>();
}

} // namespace dududu::parquet

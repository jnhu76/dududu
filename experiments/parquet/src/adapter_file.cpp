#include "dududu/parquet/adapter_file.hpp"

#include <arrow/buffer.h>
#include <arrow/result.h>
#include <arrow/status.h>

#include <utility>

namespace dududu::parquet {

AdapterFile::AdapterFile(std::unique_ptr<IoBackend> backend)
    : backend_(std::move(backend)) {}

arrow::Result<std::shared_ptr<AdapterFile>> AdapterFile::open(Arm arm, const std::string& path) {
    return open(make_backend(arm), path);
}

arrow::Result<std::shared_ptr<AdapterFile>> AdapterFile::open(std::unique_ptr<IoBackend> backend,
                                                              const std::string& path) {
    if (backend == nullptr) {
        return arrow::Status::Invalid("AdapterFile::open: null backend");
    }
    if (auto st = backend->open(path); !st.ok()) {
        return st;
    }
    return std::shared_ptr<AdapterFile>(new AdapterFile(std::move(backend)));
}

arrow::Status AdapterFile::Close() { return backend_->close(); }

bool AdapterFile::closed() const { return backend_->closed(); }

arrow::Result<int64_t> AdapterFile::Tell() const {
    std::lock_guard lock(cursor_mutex_);
    if (backend_->closed()) {
        return arrow::Status::Invalid("AdapterFile: Tell on closed file");
    }
    return cursor_;
}

arrow::Status AdapterFile::Seek(int64_t position) {
    if (position < 0) {
        return arrow::Status::Invalid("AdapterFile::Seek: negative position: ",
                                      std::to_string(position));
    }
    std::lock_guard lock(cursor_mutex_);
    if (backend_->closed()) {
        return arrow::Status::Invalid("AdapterFile: Seek on closed file");
    }
    cursor_ = position;
    return arrow::Status::OK();
}

arrow::Result<int64_t> AdapterFile::read_cursor_locked(int64_t nbytes, void* out) {
    if (nbytes < 0) {
        return arrow::Status::Invalid("AdapterFile::Read: negative length: ",
                                      std::to_string(nbytes));
    }
    if (backend_->closed()) {
        return arrow::Status::Invalid("AdapterFile: Read on closed file");
    }
    if (nbytes == 0) {
        return int64_t{0};
    }
    // One positional primitive per call — the same primitive count the native
    // ReadableFile pays for its cursor read.
    if (auto r = backend_->read_at(cursor_, nbytes, out); !r.ok()) {
        return r.status();
    } else {
        cursor_ += r.ValueOrDie();
        return r.ValueOrDie();
    }
}

arrow::Result<int64_t> AdapterFile::Read(int64_t nbytes, void* out) {
    std::lock_guard lock(cursor_mutex_);
    return read_cursor_locked(nbytes, out);
}

arrow::Result<std::shared_ptr<arrow::Buffer>> AdapterFile::Read(int64_t nbytes) {
    std::lock_guard lock(cursor_mutex_);
    if (nbytes < 0) {
        return arrow::Status::Invalid("AdapterFile::Read: negative length: ",
                                      std::to_string(nbytes));
    }
    if (backend_->closed()) {
        return arrow::Status::Invalid("AdapterFile: Read on closed file");
    }
    if (nbytes == 0) {
        return std::make_shared<arrow::Buffer>(static_cast<const uint8_t*>(nullptr), 0);
    }
    ARROW_ASSIGN_OR_RAISE(auto buf, arrow::AllocateBuffer(nbytes));
    ARROW_ASSIGN_OR_RAISE(int64_t nread, read_cursor_locked(nbytes, buf->mutable_data()));
    std::shared_ptr<arrow::Buffer> out = std::move(buf);
    if (nread < nbytes) {
        // Match the native ReadableFile behavior: report only the bytes
        // actually read, sharing the allocation (zero-copy slice).
        out = arrow::SliceBuffer(std::move(out), 0, nread);
    }
    return out;
}

arrow::Result<int64_t> AdapterFile::GetSize() { return backend_->size(); }

arrow::Result<int64_t> AdapterFile::ReadAt(int64_t position, int64_t nbytes, void* out) {
    if (auto st = validate_read_args(position, nbytes); !st.ok()) {
        return st;
    }
    if (backend_->closed()) {
        return arrow::Status::Invalid("AdapterFile: ReadAt on closed file");
    }
    if (nbytes == 0) {
        return int64_t{0};
    }
    // Deliberately cursor-free: the contract leaves the position untouched.
    return backend_->read_at(position, nbytes, out);
}

arrow::Result<std::shared_ptr<arrow::Buffer>> AdapterFile::ReadAt(int64_t position,
                                                                  int64_t nbytes) {
    if (auto st = validate_read_args(position, nbytes); !st.ok()) {
        return st;
    }
    if (backend_->closed()) {
        return arrow::Status::Invalid("AdapterFile: ReadAt on closed file");
    }
    if (nbytes == 0) {
        return std::make_shared<arrow::Buffer>(static_cast<const uint8_t*>(nullptr), 0);
    }
    ARROW_ASSIGN_OR_RAISE(auto buf, arrow::AllocateBuffer(nbytes));
    ARROW_ASSIGN_OR_RAISE(int64_t nread, backend_->read_at(position, nbytes,
                                                           buf->mutable_data()));
    std::shared_ptr<arrow::Buffer> out = std::move(buf);
    if (nread < nbytes) {
        out = arrow::SliceBuffer(std::move(out), 0, nread);
    }
    return out;
}

} // namespace dududu::parquet

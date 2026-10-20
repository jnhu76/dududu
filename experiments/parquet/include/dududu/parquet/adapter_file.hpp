#pragma once

// arrow::io::RandomAccessFile over an IoBackend.
//
// One adapter shape serves both experiment arms: P1 and P2 differ only in the
// IoBackend instance handed to open(), never in adapter code. Every read path
// the Parquet reader uses is overridden here — ReadAt (both overloads) and the
// cursor Read/Seek/Tell family — so no RandomAccessFile base default can
// silently degrade a positional read into Seek+Read.

#include <arrow/io/interfaces.h>

#include <memory>
#include <mutex>

#include "dududu/parquet/io_backend.hpp"

namespace dududu::parquet {

class AdapterFile final : public arrow::io::RandomAccessFile {
  public:
    // Arm form: constructs the arm's backend internally.
    static arrow::Result<std::shared_ptr<AdapterFile>> open(Arm arm, const std::string& path);
    // Decorator form used by tests, trace capture and benchmarks: the caller
    // picks the exact backend stack (fault injection, counters, tracing).
    static arrow::Result<std::shared_ptr<AdapterFile>> open(std::unique_ptr<IoBackend> backend,
                                                            const std::string& path);

    arrow::Status Close() override;
    bool closed() const override;
    arrow::Result<int64_t> Tell() const override;
    arrow::Status Seek(int64_t position) override;
    arrow::Result<int64_t> Read(int64_t nbytes, void* out) override;
    arrow::Result<std::shared_ptr<arrow::Buffer>> Read(int64_t nbytes) override;
    arrow::Result<int64_t> GetSize() override;
    arrow::Result<int64_t> ReadAt(int64_t position, int64_t nbytes, void* out) override;
    arrow::Result<std::shared_ptr<arrow::Buffer>> ReadAt(int64_t position,
                                                         int64_t nbytes) override;

    // The backend (or decorator stack) this adapter was opened with.
    const std::shared_ptr<IoBackend>& backend() const { return backend_; }

  private:
    explicit AdapterFile(std::unique_ptr<IoBackend> backend);

    // Cursor-locked sequential read; both Read overloads funnel here so the
    // cursor advances exactly once per call.
    arrow::Result<int64_t> read_cursor_locked(int64_t nbytes, void* out);

    std::shared_ptr<IoBackend> backend_;
    // Guards the sequential cursor only. ReadAt is position-complete and
    // takes no lock, matching the RandomAccessFile concurrency contract
    // ("can be safely called from multiple threads concurrently").
    mutable std::mutex cursor_mutex_;
    int64_t cursor_ = 0;
};

} // namespace dududu::parquet

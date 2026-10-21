#pragma once

// Transparent IoBackend decorators. They change nothing about where bytes
// come from — they only observe reads (CountingBackend, TracingBackend) or
// refuse a chosen read before it reaches the real backend (FaultInjectionBackend,
// negative controls only).

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "dududu/parquet/io_backend.hpp"

namespace dududu::parquet {

// Counts every open/close/size/read that passes through, whatever the wrapped
// backend is. Used in every experiment run of P1/P2.
class CountingBackend final : public IoBackend {
  public:
    explicit CountingBackend(std::unique_ptr<IoBackend> inner) : inner_(std::move(inner)) {}

    arrow::Status open(const std::string& path) override;
    arrow::Result<int64_t> size() override;
    arrow::Result<int64_t> read_at(int64_t offset, int64_t nbytes, void* out) override;
    arrow::Status close() override;
    bool closed() const override { return inner_->closed(); }
    const char* name() const override { return inner_->name(); }

    const IoCounters& counters() const { return counters_; }

  private:
    std::unique_ptr<IoBackend> inner_;
    IoCounters counters_;
};

// One trace entry per observed read, in call order. Tracing sits at the
// backend boundary, so every entry is a positional ReadAt(offset, length)
// request exactly as the Parquet reader issued it (cursor reads use the same
// primitive underneath the adapter). Single-threaded capture.
struct TraceEntry {
    uint64_t offset = 0;
    uint64_t requested = 0;
    uint64_t returned = 0;
    bool ok = true;
};

class TracingBackend final : public IoBackend {
  public:
    TracingBackend(std::unique_ptr<IoBackend> inner, std::vector<TraceEntry>* sink)
        : inner_(std::move(inner)), sink_(sink) {}

    arrow::Status open(const std::string& path) override {
        return inner_->open(path);
    }
    arrow::Result<int64_t> size() override { return inner_->size(); }
    arrow::Result<int64_t> read_at(int64_t offset, int64_t nbytes, void* out) override;
    arrow::Status close() override { return inner_->close(); }
    bool closed() const override { return inner_->closed(); }
    const char* name() const override { return inner_->name(); }

    const std::vector<TraceEntry>& entries() const { return *sink_; }

  private:
    std::unique_ptr<IoBackend> inner_;
    std::vector<TraceEntry>* sink_;
};

// Negative-control decorator: fails the Nth read_at (0-based) before the
// wrapped backend sees it. `fail_every_read` hardens the control into
// "no read at all may pass". These injections are how the tests prove that
// the Parquet reader really reaches the arm's own backend.
class FaultInjectionBackend final : public IoBackend {
  public:
    explicit FaultInjectionBackend(std::unique_ptr<IoBackend> inner) : inner_(std::move(inner)) {}

    void fail_read_at_at(int64_t call_index, arrow::StatusCode code, std::string message);
    void fail_every_read(arrow::StatusCode code, std::string message);
    void disarm();

    arrow::Status open(const std::string& path) override { return inner_->open(path); }
    arrow::Result<int64_t> size() override { return inner_->size(); }
    arrow::Result<int64_t> read_at(int64_t offset, int64_t nbytes, void* out) override;
    arrow::Status close() override { return inner_->close(); }
    bool closed() const override { return inner_->closed(); }
    const char* name() const override { return inner_->name(); }

    // read_at invocations that passed through this decorator (faulting or not).
    int64_t read_at_calls() const { return read_at_calls_; }

  private:
    std::unique_ptr<IoBackend> inner_;
    int64_t fail_index_ = -1;
    bool fail_all_ = false;
    arrow::StatusCode code_ = arrow::StatusCode::IOError;
    std::string message_;
    int64_t read_at_calls_ = 0;
};

// Fake "backend" used only as a negative oracle control: it claims success
// but moves zero bytes — every read returns EOF. A pipeline that accepted its
// output as a benchmark or correctness result would be broken; the reader
// must fail on it. (A buffer-filling fake would feed the page parser stale
// memory and could loop; "reads nothing" is the honest zero-implementation.)
class FakeZeroBackend final : public IoBackend {
  public:
    arrow::Status open(const std::string& path) override {
        path_ = path;
        closed_ = false;
        return arrow::Status::OK();
    }
    arrow::Result<int64_t> size() override {
        if (closed_) {
            return arrow::Status::Invalid("fake: closed");
        }
        return size_;
    }
    void set_size(int64_t size) { size_ = size; }
    arrow::Result<int64_t> read_at(int64_t offset, int64_t nbytes, void* out) override {
        (void)offset;
        (void)nbytes;
        (void)out; // deliberately untouched: this backend never moves bytes
        if (closed_) {
            return arrow::Status::Invalid("fake: closed");
        }
        return int64_t{0}; // fake success, zero bytes delivered
    }
    arrow::Status close() override {
        closed_ = true;
        return arrow::Status::OK();
    }
    bool closed() const override { return closed_; }
    const char* name() const override { return "fake-zero"; }

  private:
    std::string path_;
    int64_t size_ = 0;
    bool closed_ = true;
};

} // namespace dududu::parquet

#include "dududu/parquet/io_decorators.hpp"

#include <arrow/status.h>

namespace dududu::parquet {

void IoCounters::observe_read_at(uint64_t offset, uint64_t requested, uint64_t returned,
                                 bool ok) {
    ++read_at_calls;
    requested_bytes += requested;
    returned_bytes += returned;
    if (!ok) {
        ++read_errors;
    }
    if (offset < min_offset) {
        min_offset = offset;
    }
    if (offset > max_offset) {
        max_offset = offset;
    }
    unsigned bucket = 0;
    uint64_t v = requested;
    while (v > 1 && bucket + 1 < size_hist.size()) {
        v >>= 1;
        ++bucket;
    }
    ++size_hist[bucket];
}

void IoCounters::merge(const IoCounters& other) {
    read_at_calls += other.read_at_calls;
    requested_bytes += other.requested_bytes;
    returned_bytes += other.returned_bytes;
    read_errors += other.read_errors;
    opens += other.opens;
    closes += other.closes;
    if (other.min_offset < min_offset) {
        min_offset = other.min_offset;
    }
    if (other.max_offset > max_offset) {
        max_offset = other.max_offset;
    }
    for (size_t i = 0; i < size_hist.size(); ++i) {
        size_hist[i] += other.size_hist[i];
    }
}

// --- CountingBackend --------------------------------------------------------

arrow::Status CountingBackend::open(const std::string& path) {
    ++counters_.opens;
    return inner_->open(path);
}

arrow::Result<int64_t> CountingBackend::size() {
    return inner_->size();
}

arrow::Result<int64_t> CountingBackend::read_at(int64_t offset, int64_t nbytes, void* out) {
    auto r = inner_->read_at(offset, nbytes, out);
    counters_.observe_read_at(static_cast<uint64_t>(offset), static_cast<uint64_t>(nbytes),
                              r.ok() ? static_cast<uint64_t>(r.ValueOrDie()) : 0, r.ok());
    return r;
}

arrow::Status CountingBackend::close() {
    ++counters_.closes;
    return inner_->close();
}

// --- TracingBackend ---------------------------------------------------------

arrow::Result<int64_t> TracingBackend::read_at(int64_t offset, int64_t nbytes, void* out) {
    auto r = inner_->read_at(offset, nbytes, out);
    sink_->push_back(TraceEntry{
        .offset = static_cast<uint64_t>(offset),
        .requested = static_cast<uint64_t>(nbytes),
        .returned = r.ok() ? static_cast<uint64_t>(r.ValueOrDie()) : 0,
        .ok = r.ok(),
    });
    return r;
}

// --- FaultInjectionBackend --------------------------------------------------

void FaultInjectionBackend::fail_read_at_at(int64_t call_index, arrow::StatusCode code,
                                            std::string message) {
    fail_index_ = call_index;
    fail_all_ = false;
    code_ = code;
    message_ = std::move(message);
}

void FaultInjectionBackend::fail_every_read(arrow::StatusCode code, std::string message) {
    fail_index_ = -1;
    fail_all_ = true;
    code_ = code;
    message_ = std::move(message);
}

void FaultInjectionBackend::disarm() {
    fail_index_ = -1;
    fail_all_ = false;
}

arrow::Result<int64_t> FaultInjectionBackend::read_at(int64_t offset, int64_t nbytes,
                                                      void* out) {
    const int64_t index = read_at_calls_++;
    if (fail_all_ || index == fail_index_) {
        return arrow::Status(code_, message_ + " [injected at read " + std::to_string(index) +
                                        " offset=" + std::to_string(offset) + "]");
    }
    return inner_->read_at(offset, nbytes, out);
}

} // namespace dududu::parquet

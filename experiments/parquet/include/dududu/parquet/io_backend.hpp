#pragma once

// Read-backend seam for the standalone Parquet arms (experiments/parquet).
//
// P0 (arrow native) never passes through here: it hands arrow::io::ReadableFile
// straight to the Parquet reader. P1 and P2 are one identical adapter over two
// interchangeable backends, so the only thing the reader can observe is the
// backend itself:
//   p1-native ::pread on a plain descriptor      (src/backend_native.cpp)
//   p2-sluice sluice::blocking::read_at on a
//             sluice::File                       (src/backend_sluice.cpp)
// Neither backend falls back to the other: construction is explicit, and each
// backend translation unit contains exactly one byte-moving primitive.

#include <arrow/result.h>
#include <arrow/status.h>

#include <array>
#include <cstdint>
#include <memory>
#include <string>

namespace dududu::parquet {

enum class Arm { p0_arrow, p1_native, p2_sluice };

const char* arm_name(Arm arm);

class IoBackend {
 public:
  virtual ~IoBackend() = default;

  // Open `path` read-only. Exactly one open per instance.
  virtual arrow::Status open(const std::string& path) = 0;

  // Total size in bytes. Independent of, and without moving, any cursor.
  virtual arrow::Result<int64_t> size() = 0;

  // Positional read: at most `nbytes` bytes at `offset`. May return fewer
  // bytes (short read); returns 0 exactly when `offset` is at or after EOF.
  // A legal EOF is a zero-byte success, never an error; a backend failure is
  // never disguised as a zero-byte success.
  // Negative or overflowing arguments are rejected with Invalid before any
  // I/O happens; after close() this fails.
  virtual arrow::Result<int64_t> read_at(int64_t offset, int64_t nbytes, void* out) = 0;

  // Idempotent. Concurrent reads and close are caller-serialized, matching
  // the Sluice borrow rules and POSIX practice alike.
  virtual arrow::Status close() = 0;
  virtual bool closed() const = 0;
  virtual const char* name() const = 0;
};

// Internal construction hooks; `make_backend` is the only public entry.
std::unique_ptr<IoBackend> make_native_backend();
std::unique_ptr<IoBackend> make_sluice_backend();

// No backend exists for P0 by construction — wrapping Arrow's own file would
// stop it being the native baseline. A null return for p0_arrow (checked by
// AdapterFile::open) means an arm can never be silently substituted by
// another one.
inline std::unique_ptr<IoBackend> make_backend(Arm arm) {
    switch (arm) {
    case Arm::p1_native: return make_native_backend();
    case Arm::p2_sluice: return make_sluice_backend();
    case Arm::p0_arrow: break;
    }
    return nullptr;
}

// Shared argument contract for both backends, so P1 and P2 reject (or accept)
// exactly the same requests before any I/O happens.
arrow::Status validate_read_args(int64_t offset, int64_t nbytes);

// Cumulative I/O observability gathered by the counting decorator. Plain
// integers: one workload run is single-threaded. The 4-thread benchmark
// reports time only and uses per-iteration private handles, so counters are
// never shared across threads.
struct IoCounters {
    uint64_t read_at_calls = 0;
    uint64_t requested_bytes = 0;
    uint64_t returned_bytes = 0;
    uint64_t read_errors = 0;
    uint64_t opens = 0;
    uint64_t closes = 0;
    uint64_t min_offset = UINT64_MAX;
    uint64_t max_offset = 0;
    // log2 requested-length histogram of read_at calls; bucket k holds
    // requests with 2^k <= requested < 2^(k+1). Length 0 lands in bucket 0.
    std::array<uint64_t, 33> size_hist{};

    void observe_read_at(uint64_t offset, uint64_t requested, uint64_t returned, bool ok);
};

} // namespace dududu::parquet

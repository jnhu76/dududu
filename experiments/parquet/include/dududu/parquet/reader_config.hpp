#pragma once

// Frozen reader configuration, applied identically on every arm and on every
// trace capture. One knob matters here:
//
//   pre_buffer = false
//
// Arrow's default pre-buffering coalesces the reader's column-chunk ranges
// through the ReadRangeCache and can collapse a full scan into one
// whole-file ReadAt. That hides the request pattern this experiment is
// trying to observe, so it is turned off for all arms alike. Everything else
// stays at the Arrow defaults (unbuffered stream, default cache).

#include <parquet/arrow/reader.h>

namespace dududu::parquet {

inline void configure_reader(::parquet::arrow::FileReaderBuilder& builder) {
    ::parquet::ArrowReaderProperties props; // Arrow defaults ...
    props.set_pre_buffer(false);            // ... except the coalescing pre-buffer
    builder.properties(props);
}

} // namespace dududu::parquet

#pragma once

// Minimal FIPS 180-4 SHA-256 for dataset manifests and oracle digests.
// Local and dependency-free on purpose: the oracle must be reproducible from
// the repository alone, with no linkage variance.

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

namespace dududu::parquet {

class Sha256 {
  public:
    Sha256();
    void update(const void* data, std::size_t bytes);
    // Hex digest (64 lowercase characters); finalizes this instance.
    std::string hex_digest();

  private:
    void compress(const std::uint8_t block[64]);

    std::uint32_t h_[8];
    std::uint8_t buf_[64];
    std::size_t buf_len_ = 0;
    std::uint64_t total_ = 0;
};

std::string sha256_hex(std::string_view data);

// Streaming digest of a file's bytes; empty path or unreadable file returns "".
std::string sha256_file(const std::string& path);

} // namespace dududu::parquet

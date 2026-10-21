// parquet_fixture: deterministic dataset generation entry point.
//
//   parquet_fixture --out <dir> --dataset small|medium [--compression none|snappy]
//
// Writes <dir>/<dataset>-<compression>.parquet plus <dir>/manifest.json
// (frozen parameters, byte size, SHA-256, toolchain identities). Generation
// time never enters any benchmark sample.

#include <arrow/util/config.h>

#include <cstdio>
#include <cstring>
#include <string>

#include "dududu/parquet/fixture.hpp"
#include "dududu/parquet/sha256.hpp"

namespace {

void usage() {
    std::fputs("usage: parquet_fixture --out <dir> --dataset small|medium "
               "[--compression none|snappy]\n",
               stderr);
}

} // namespace

int main(int argc, char** argv) {
    std::string out_dir, dataset, compression = "none";
    for (int i = 1; i < argc; ++i) {
        const auto arg = std::string(argv[i]);
        auto next = [&]() -> const char* {
            return i + 1 < argc ? argv[i + 1] : nullptr;
        };
        if (arg == "--out" && next() != nullptr) {
            out_dir = next();
            ++i;
        } else if (arg == "--dataset" && next() != nullptr) {
            dataset = next();
            ++i;
        } else if (arg == "--compression" && next() != nullptr) {
            compression = next();
            ++i;
        } else {
            usage();
            return 2;
        }
    }
    if (out_dir.empty() || dataset.empty()) {
        usage();
        return 2;
    }

    auto generated = dududu::parquet::generate_fixture(dataset, out_dir, compression);
    if (!generated.ok()) {
        std::fprintf(stderr, "parquet_fixture: %s\n", generated.status().ToString().c_str());
        return 1;
    }

    // Manifest: the freeze record for this dataset instance.
    const std::string manifest_path = out_dir + "/manifest-" + dataset + "-" + compression +
                                      ".json";
    std::string manifest = "{\n";
    manifest += "  \"dataset\": \"" + dataset + "\",\n";
    manifest += "  \"compression\": \"" + compression + "\",\n";
    manifest += "  \"path\": \"" + generated->path + "\",\n";
    manifest += "  \"bytes\": " + std::to_string(generated->bytes) + ",\n";
    manifest += "  \"sha256\": \"" + generated->sha256 + "\",\n";
    manifest += "  \"seed\": \"0xD4D4D420261020\",\n";
#ifdef ARROW_VERSION_STRING
    manifest += "  \"arrow_version\": \"" ARROW_VERSION_STRING "\",\n";
#endif
    manifest += "  \"generator\": \"parquet_fixture\"\n}\n";
    FILE* f = std::fopen(manifest_path.c_str(), "wb");
    if (f == nullptr) {
        std::fprintf(stderr, "parquet_fixture: manifest write failed: %s\n",
                     manifest_path.c_str());
        return 1;
    }
    std::fwrite(manifest.data(), 1, manifest.size(), f);
    std::fclose(f);

    std::printf("parquet_fixture: %s bytes=%lld sha256=%s\n",
                generated->path.c_str(), static_cast<long long>(generated->bytes),
                generated->sha256.c_str());
    return 0;
}

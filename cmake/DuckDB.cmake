# DuckDB native baseline build bridge.
#
# DuckDB is built by its own upstream CMake project, unmodified. dududu only
# selects documented upstream options and pins the output directory. The
# `duckdb_native` target must remain a byte-for-byte upstream source build:
# no patches, no extra defines, no host-side workaround that would make D0 an
# implicit fork.

include_guard(GLOBAL)

include(ExternalProject)

set(DUDUDU_DUCKDB_SOURCE_DIR "${PROJECT_SOURCE_DIR}/third_party/duckdb"
    CACHE PATH "Checked-out DuckDB submodule at the pinned stable release")

function(dududu_add_duckdb_native)
  set(bin_dir "${DUDUDU_BUILD_ROOT}/duckdb-native")

  set(shell_bin "${bin_dir}/duckdb")
  set(unittest_bin "${bin_dir}/test/unittest")
  set(benchmark_bin "${bin_dir}/benchmark/benchmark_runner")

  ExternalProject_Add(duckdb_native
    PREFIX "${DUDUDU_BUILD_ROOT}/ep/duckdb"
    SOURCE_DIR "${DUDUDU_DUCKDB_SOURCE_DIR}"
    BINARY_DIR "${bin_dir}"
    CMAKE_GENERATOR "Ninja"
    CMAKE_ARGS
      -DCMAKE_BUILD_TYPE=Release
      -DBUILD_SHELL=ON
      -DBUILD_UNITTESTS=ON
      -DBUILD_BENCHMARKS=ON
      # parquet is a built-in essential extension; tpch is opt-in and is the
      # official benchmark data source used by the R0 smoke.
      -DBUILD_EXTENSIONS=tpch
      -DENABLE_SANITIZER=OFF
      -DENABLE_UBSAN=OFF
      # DuckDB's cmake_minimum_required floor is older than the local CMake 4
      # default policy window; this restores the upstream-declared policy
      # minimum instead of letting CMake 4 reject the project.
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    BUILD_BYPRODUCTS "${shell_bin}" "${unittest_bin}" "${benchmark_bin}"
    INSTALL_COMMAND ""
    UPDATE_COMMAND ""
    BUILD_ALWAYS FALSE
    USES_TERMINAL TRUE
    LOG_CONFIGURE TRUE
    LOG_BUILD TRUE
  )

  message(STATUS "DuckDB native: source=${DUDUDU_DUCKDB_SOURCE_DIR} binary=${bin_dir}")
endfunction()

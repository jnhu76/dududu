# DuckDB native baseline build bridge.
#
# DuckDB is built by its own upstream CMake project, unmodified. dududu only
# selects documented upstream options and pins the output directory. The
# `duckdb_native` target must remain a byte-for-byte upstream source build:
# no patches, no extra defines, no host-side workaround that would make D0 an
# implicit fork.
#
# Build identity (review B2): the external build is stamp-driven and has no
# dependency on submodule content, so a bare `ExternalProject_Add` keeps the
# previous release running after a `git submodule update`. The binary dir and
# the ExternalProject prefix (stamps + logs) are therefore bound to the
# submodule's full HEAD SHA at configure time, and the parent build re-runs
# CMake when that HEAD moves. A gitlink change can then only produce a fresh,
# SHA-scoped build tree; the previous tree is left untouched as evidence.
# Every consumer path must resolve through DUDUDU_DUCKDB_BIN_DIR — a literal
# path anywhere would silently pin one generation.

include_guard(GLOBAL)

include(ExternalProject)

set(DUDUDU_DUCKDB_SOURCE_DIR "${PROJECT_SOURCE_DIR}/third_party/duckdb"
    CACHE PATH "Checked-out DuckDB submodule at the pinned stable release")

# Resolve <source_dir>'s full HEAD SHA, export it, and register the files whose
# change must force a parent reconfigure. A submodule update checks out a
# detached HEAD (the HEAD file content changes); a branch move rewrites the
# loose ref (or packed-refs), so all three are watched.
function(dududu_duckdb_gitlink_identity source_dir out_sha)
  find_package(Git REQUIRED)

  execute_process(COMMAND "${GIT_EXECUTABLE}" -C "${source_dir}" rev-parse --absolute-git-dir
                  OUTPUT_VARIABLE git_dir RESULT_VARIABLE rc
                  OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
  execute_process(COMMAND "${GIT_EXECUTABLE}" -C "${source_dir}" rev-parse HEAD
                  OUTPUT_VARIABLE sha RESULT_VARIABLE rc
                  OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
  if(NOT rc EQUAL 0 OR sha STREQUAL "")
    message(FATAL_ERROR
            "DuckDB identity: cannot resolve the HEAD SHA of '${source_dir}'. "
            "Rule 1 of AGENTS.md: a build without a resolvable DuckDB SHA is not a build.")
  endif()

  set(watched "${git_dir}/HEAD")
  file(READ "${git_dir}/HEAD" head_content)
  if(head_content MATCHES "ref:[ \t]+([^ \t\r\n]+)")
    list(APPEND watched "${git_dir}/${CMAKE_MATCH_1}")
  endif()
  if(EXISTS "${git_dir}/packed-refs")
    list(APPEND watched "${git_dir}/packed-refs")
  endif()
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${watched})

  set(${out_sha} "${sha}" PARENT_SCOPE)
endfunction()

function(dududu_add_duckdb_native)
  dududu_duckdb_gitlink_identity("${DUDUDU_DUCKDB_SOURCE_DIR}" duckdb_sha)

  set(bin_dir "${DUDUDU_BUILD_ROOT}/duckdb-native/${duckdb_sha}")
  set(ep_prefix "${DUDUDU_BUILD_ROOT}/ep/duckdb/${duckdb_sha}")

  set(shell_bin "${bin_dir}/duckdb")
  set(unittest_bin "${bin_dir}/test/unittest")
  set(benchmark_bin "${bin_dir}/benchmark/benchmark_runner")

  ExternalProject_Add(duckdb_native
    PREFIX "${ep_prefix}"
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

  set(DUDUDU_DUCKDB_SHA "${duckdb_sha}" PARENT_SCOPE)
  set(DUDUDU_DUCKDB_BIN_DIR "${bin_dir}" PARENT_SCOPE)

  message(STATUS
          "DuckDB native: sha=${duckdb_sha} source=${DUDUDU_DUCKDB_SOURCE_DIR} binary=${bin_dir} "
          "(SHA-scoped: a submodule update starts a fresh full build in a new directory)")
endfunction()

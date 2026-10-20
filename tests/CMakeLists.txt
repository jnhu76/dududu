# Consumer smoke tests over the installed Sluice SDK, plus official DuckDB
# smoke entry points. Every test here consumes installed artifacts or upstream
# binaries; none of them reaches into a submodule source tree.
#
# The build-mechanics block at the bottom is different: those tests replay the
# bridge mechanisms against fixtures so that a stale-binary or stale-SDK
# regression fails as a red CTest instead of silently invalidating an
# experiment (review B2).

set(DUDUDU_SLUICE_SDK_NOLIBURING "${DUDUDU_BUILD_ROOT}/sluice-sdk/noliburing")
set(DUDUDU_SLUICE_SDK_LIBURING "${DUDUDU_BUILD_ROOT}/sluice-sdk/liburing")

# --- Sluice consumers -------------------------------------------------------
add_executable(sluice_core_consumer sluice-sdk/core_consumer.cpp)
dududu_link_sluice(sluice_core_consumer core)
add_test(NAME sluice.sdk.core COMMAND sluice_core_consumer)

add_executable(sluice_threadpool_consumer sluice-sdk/threadpool_consumer.cpp)
dududu_link_sluice(sluice_threadpool_consumer async)
add_test(NAME sluice.sdk.async.threadpool COMMAND sluice_threadpool_consumer)

add_executable(sluice_uring_consumer sluice-sdk/uring_consumer.cpp)
dududu_link_sluice(sluice_uring_consumer async_uring)
add_test(NAME sluice.sdk.async.uring COMMAND sluice_uring_consumer)
# Exit 2 is the documented NOT_SUPPORTED outcome (no io_uring in this
# environment). CTest reports it as skipped, never as a pass.
set_tests_properties(sluice.sdk.async.uring PROPERTIES SKIP_RETURN_CODE 2)

add_executable(sluice_uring_absence sluice-sdk/uring_absence_consumer.cpp)
dududu_link_sluice(sluice_uring_absence async)
add_test(NAME sluice.sdk.async.uring-absence COMMAND sluice_uring_absence)

# --- Installed-surface boundary --------------------------------------------
add_test(NAME sluice.sdk.header-boundary
         COMMAND ${CMAKE_COMMAND}
                 -DSDK_DIR=${DUDUDU_SLUICE_SDK_NOLIBURING}
                 -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/VerifySdkBoundary.cmake)

# --- DuckDB official entry points ------------------------------------------
if(TARGET duckdb_native)
  # DUDUDU_DUCKDB_BIN_DIR is exported by cmake/DuckDB.cmake and is
  # SHA-scoped: a submodule update builds into a new directory and this path
  # moves with it. Never recompute a literal path here.
  set(DUDUDU_DUCKDB_SHELL "${DUDUDU_DUCKDB_BIN_DIR}/duckdb")
  set(DUDUDU_DUCKDB_UNITTEST "${DUDUDU_DUCKDB_BIN_DIR}/test/unittest")
  set(DUDUDU_DUCKDB_BENCHMARK "${DUDUDU_DUCKDB_BIN_DIR}/benchmark/benchmark_runner")

  add_test(NAME duckdb.shell.smoke
           COMMAND ${CMAKE_COMMAND}
                   -DDUCKDB_BIN=${DUDUDU_DUCKDB_SHELL}
                   -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/RunDuckdbShellSmoke.cmake)

  add_test(NAME duckdb.unittest.smoke
           COMMAND ${CMAKE_COMMAND}
                   -DUNITTEST_BIN=${DUDUDU_DUCKDB_UNITTEST}
                   -DDUCKDB_SOURCE_DIR=${DUDUDU_DUCKDB_SOURCE_DIR}
                   -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/RunDuckdbUnittestSmoke.cmake)

  add_test(NAME duckdb.benchmark.list
           COMMAND ${CMAKE_COMMAND}
                   -DBENCHMARK_BIN=${DUDUDU_DUCKDB_BENCHMARK}
                   -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/RunDuckdbBenchmarkList.cmake)

  # DUCKDB_SOURCE_DIR lets the script expose the interpreted `.benchmark` files
  # (which the runner discovers under <root>/benchmark) to a scratch root dir.
  # ROOT_DIR is required: the runner's default root is the DuckDB source tree
  # and it writes generated data there. Keeping the root inside the ignored
  # build tree is what makes "DuckDB sources unmodified" verifiable after the
  # test has run.
  add_test(NAME duckdb.benchmark.smoke
           COMMAND ${CMAKE_COMMAND}
                   -DBENCHMARK_BIN=${DUDUDU_DUCKDB_BENCHMARK}
                   -DDUCKDB_SOURCE_DIR=${DUDUDU_DUCKDB_SOURCE_DIR}
                   "-DBENCHMARK_NAME=benchmark/tpch/parquet/parquet_projection_direct.benchmark"
                   "-DROOT_DIR=${DUDUDU_BUILD_ROOT}/duckdb-bench"
                   -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/RunDuckdbBenchmarkSmoke.cmake)
  # The upstream data generation dominates this test's runtime; it is R0
  # entry-point evidence, not part of the fast loop.
  set_tests_properties(duckdb.benchmark.smoke PROPERTIES LABELS "slow" TIMEOUT 1800)
endif()

# --- Build-mechanics negative proofs ----------------------------------------
# Replays the DuckDB bridge against a stub git-repository source: after any
# gitlink move (branch or detached), the consumed binary must come from the
# new SHA's fresh build tree, never from the previous generation. Runs the
# real cmake/DuckDB.cmake; no upstream source or network involved.
add_test(NAME duckdb.build.sha-refresh
         COMMAND ${CMAKE_COMMAND}
                 "-DFIXTURE_ROOT=${CMAKE_BINARY_DIR}/fixture/duckdb-sha-refresh"
                 "-DDUDUDU_CMAKE_DIR=${CMAKE_SOURCE_DIR}/cmake"
                 -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/RunDuckdbShaRefreshFixture.cmake)

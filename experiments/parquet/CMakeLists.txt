# Standalone Parquet x Sluice experiment (R1).
#
# Whole directory is behind DUDUDU_ENABLE_PARQUET, so the default and
# sluice-only configurations never see Arrow. Enabling it without the Arrow,
# Parquet and Google Benchmark packages present is a hard configure error,
# never a silent skip.

find_package(Arrow REQUIRED)
find_package(Parquet REQUIRED)
find_package(benchmark CONFIG REQUIRED)

message(STATUS "Parquet experiment: Arrow ${Arrow_VERSION}, Parquet ${Parquet_VERSION}")

set(DUDUDU_PARQUET_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/include")

add_library(dududu_parquet STATIC
  src/sha256.cpp
  src/backend_native.cpp    # P1: the only TU with a pread (plus shared arg contract)
  src/backend_sluice.cpp    # P2: the only TU with sluice headers
  src/adapter_file.cpp
  src/io_decorators.cpp
  src/fixture.cpp
  src/oracle.cpp
  src/runner.cpp
  src/io_trace.cpp)
target_include_directories(dududu_parquet PUBLIC ${DUDUDU_PARQUET_INCLUDE_DIR})
target_link_libraries(dududu_parquet PUBLIC Arrow::arrow_shared Parquet::parquet_shared)
target_compile_features(dududu_parquet PUBLIC cxx_std_20)
# P2's byte mover lives in the installed Sluice SDK; GNU archive order is
# handled by dududu_link_sluice.
dududu_link_sluice(dududu_parquet core)

add_executable(parquet_fixture src/tools/fixture_main.cpp)
target_link_libraries(parquet_fixture PRIVATE dududu_parquet)

add_executable(parquet_trace src/tools/trace_main.cpp)
target_link_libraries(parquet_trace PRIVATE dududu_parquet)

add_executable(parquet_bench src/tools/bench_main.cpp)
target_link_libraries(parquet_bench PRIVATE dududu_parquet benchmark::benchmark)

enable_testing()

add_executable(parquet_contract_test tests/parquet_contract.cpp)
target_link_libraries(parquet_contract_test PRIVATE dududu_parquet)
add_test(NAME parquet.contract COMMAND parquet_contract_test)

add_executable(parquet_oracle_test tests/parquet_oracle.cpp)
target_link_libraries(parquet_oracle_test PRIVATE dududu_parquet)
add_test(NAME parquet.oracle COMMAND parquet_oracle_test)

add_executable(parquet_trace_test tests/parquet_trace.cpp)
target_link_libraries(parquet_trace_test PRIVATE dududu_parquet)
add_test(NAME parquet.trace COMMAND parquet_trace_test)

# Protocol-tooling self-test (negative-first Bash + jq). jq is part of the
# benchmark toolchain already (summarize.sh); a missing jq is a loud
# configure error, never a silent skip of the evidence gate.
find_program(DUDUDU_JQ_EXECUTABLE jq)
if(NOT DUDUDU_JQ_EXECUTABLE)
  message(FATAL_ERROR "jq not found: the parquet protocol self-test needs it")
endif()
add_test(NAME parquet.trace.jsonl
         COMMAND bash "${CMAKE_SOURCE_DIR}/benchmarks/parquet/tests/validate-trace-test.sh")
add_test(NAME parquet.bench.admit
         COMMAND bash "${CMAKE_SOURCE_DIR}/benchmarks/parquet/tests/validate-results-test.sh")

set_tests_properties(parquet.contract parquet.oracle parquet.trace parquet.trace.jsonl
  parquet.bench.admit PROPERTIES
  LABELS "parquet"
  TIMEOUT 600)

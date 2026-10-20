# Standalone Parquet x Sluice experiment (R1).
#
# Whole directory is behind DUDUDU_ENABLE_PARQUET, so the default and
# sluice-only configurations never see Arrow. Enabling it without the Arrow,
# Parquet and Google Benchmark packages present is a hard configure error,
# never a silent skip.
#
# This file grows with the experiment: targets appear together with the
# sources that back them.

find_package(Arrow REQUIRED)
find_package(Parquet REQUIRED)
find_package(benchmark CONFIG REQUIRED)

message(STATUS "Parquet experiment: Arrow ${Arrow_VERSION}, Parquet ${Parquet_VERSION}")

set(DUDUDU_PARQUET_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/include")

add_library(dududu_parquet STATIC
  src/sha256.cpp
  src/fixture.cpp
  src/backend_native.cpp    # P1: the only TU with a pread
  src/backend_sluice.cpp    # P2: the only TU with sluice headers
  src/adapter_file.cpp
  src/io_decorators.cpp
  src/oracle.cpp
  src/runner.cpp)
target_include_directories(dududu_parquet PUBLIC ${DUDUDU_PARQUET_INCLUDE_DIR})
target_link_libraries(dududu_parquet PUBLIC Arrow::arrow_shared Parquet::parquet_shared)
target_compile_features(dududu_parquet PUBLIC cxx_std_20)
# P2's byte mover lives in the installed Sluice SDK; GNU archive order is
# handled by dududu_link_sluice.
dududu_link_sluice(dududu_parquet core)

add_executable(parquet_fixture src/tools/fixture_main.cpp)
target_link_libraries(parquet_fixture PRIVATE dududu_parquet)

enable_testing()

add_executable(parquet_contract_test tests/parquet_contract.cpp)
target_link_libraries(parquet_contract_test PRIVATE dududu_parquet)
add_test(NAME parquet.contract COMMAND parquet_contract_test)

add_executable(parquet_oracle_test tests/parquet_oracle.cpp)
target_link_libraries(parquet_oracle_test PRIVATE dududu_parquet)
add_test(NAME parquet.oracle COMMAND parquet_oracle_test)

set_tests_properties(parquet.contract parquet.oracle PROPERTIES
  LABELS "parquet"
  TIMEOUT 600)

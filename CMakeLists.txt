cmake_minimum_required(VERSION 3.24)
project(dududu LANGUAGES C CXX)

# dududu is an experiment harness around two owned-by-submodule upstreams:
#   * Sluice  (xmake)  -> static SDK consumed through cmake/Sluice.cmake
#   * DuckDB  (CMake)  -> unmodified native baseline via cmake/DuckDB.cmake
# CMake's job here is build orchestration and experiment targets only.

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(DUDUDU_BUILD_SLUICE_SDK "Build the Sluice static SDK through xmake" ON)
option(DUDUDU_BUILD_DUCKDB_NATIVE "Build the unmodified DuckDB native baseline" ON)
option(DUDUDU_BUILD_TESTS "Configure CTest consumers and smoke tests" ON)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
include(Sluice)
include(DuckDB)

if(DUDUDU_BUILD_SLUICE_SDK)
  dududu_add_sluice()
endif()

if(DUDUDU_BUILD_DUCKDB_NATIVE)
  dududu_add_duckdb_native()
endif()

if(DUDUDU_BUILD_TESTS)
  enable_testing()
  if(DUDUDU_BUILD_SLUICE_SDK)
    add_subdirectory(tests)
  endif()
endif()

# DuckDB official benchmark smoke: run exactly one registered benchmark and
# require the upstream result oracle to pass.
#
# The runner itself evaluates the benchmark's `result` statement; a mismatch
# makes it exit non-zero. R0 only establishes that this entry point works — it
# draws no performance conclusion from the numbers.
#
# Invoked as:
#   cmake -DBENCHMARK_BIN=<bin> -DBENCHMARK_NAME=<name> -P RunDuckdbBenchmarkSmoke.cmake
#
# BENCHMARK_NAME is the exact name printed by `benchmark_runner --list`.

if(NOT DEFINED BENCHMARK_BIN OR NOT EXISTS "${BENCHMARK_BIN}")
  message(FATAL_ERROR "DuckDB benchmark_runner not found: ${BENCHMARK_BIN}")
endif()
if(NOT DEFINED BENCHMARK_NAME OR BENCHMARK_NAME STREQUAL "")
  message(FATAL_ERROR "BENCHMARK_NAME is required (take it from --list)")
endif()

set(out_file "/tmp/dududu_benchmark_smoke.json")
file(REMOVE "${out_file}")

execute_process(
  COMMAND "${BENCHMARK_BIN}" "--benchmark=${BENCHMARK_NAME}" "--out=${out_file}"
  WORKING_DIRECTORY "/tmp"
  OUTPUT_VARIABLE out
  ERROR_VARIABLE err
  RESULT_VARIABLE rc
  TIMEOUT 900)

message(STATUS "benchmark stdout:\n${out}")
if(NOT rc EQUAL 0)
  message(FATAL_ERROR "benchmark smoke failed (rc=${rc}) for ${BENCHMARK_NAME}\nstderr:\n${err}")
endif()

if(NOT EXISTS "${out_file}")
  message(FATAL_ERROR "benchmark runner produced no output file: ${out_file}")
endif()

file(SIZE "${out_file}" out_size)
if(out_size LESS 10)
  message(FATAL_ERROR "benchmark output file is empty: ${out_file}")
endif()

message(STATUS "duckdb benchmark smoke: PASS (${BENCHMARK_NAME}, ${out_size} bytes)")

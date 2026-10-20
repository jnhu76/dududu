# DuckDB official benchmark smoke: run exactly one registered benchmark and
# require the upstream result oracle to pass.
#
# Invoked as:
#   cmake -DBENCHMARK_BIN=<bin> -DBENCHMARK_NAME=<name>
#         -DDUCKDB_SOURCE_DIR=<pinned duckdb checkout> -DROOT_DIR=<ignored dir>
#         -P RunDuckdbBenchmarkSmoke.cmake
#
# BENCHMARK_NAME is the exact name printed by `benchmark_runner --list`.
#
# Two facts about the runner shape this script, both verified against the
# pinned v1.5.6 sources (benchmark/benchmark_runner.cpp):
#
# 1. The benchmark is selected by a POSITIONAL name pattern (regex over name and
#    group). There is no `--benchmark=` flag: an unknown `--x=y` is parsed as a
#    custom benchmark argument, which runs every registered benchmark and then
#    aborts in whichever benchmark validates that argument.
#
# 2. The process exit code does NOT reflect result correctness. `run_benchmarks`
#    returns a ConfigurationError, and main exits 1 only for "benchmark not
#    found" / "info without name". A benchmark whose `result` statement does not
#    match logs INCORRECT into the --out stream and exits 0. So the correctness
#    check has to read the output file, not the exit status.
#
# `--root-dir` is mandatory and is also the directory scanned for the
# `benchmark/` tree of interpreted `.benchmark` files. Pointing it at a scratch
# directory would therefore find zero benchmarks, so this script links the
# pinned source's `benchmark/` directory into ROOT_DIR instead of copying it,
# and runs the benchmark there. That keeps generated dbgen/parquet/db files out
# of third_party/duckdb (the runner's default root is DUCKDB_ROOT_DIRECTORY,
# the source tree — this was observed writing ~200 MB into the submodule during
# R0 and had to be cleaned up).

if(NOT DEFINED BENCHMARK_BIN OR NOT EXISTS "${BENCHMARK_BIN}")
  message(FATAL_ERROR "DuckDB benchmark_runner not found: ${BENCHMARK_BIN}")
endif()
if(NOT DEFINED BENCHMARK_NAME OR BENCHMARK_NAME STREQUAL "")
  message(FATAL_ERROR "BENCHMARK_NAME is required (take it from --list)")
endif()
if(NOT DEFINED DUCKDB_SOURCE_DIR OR DUCKDB_SOURCE_DIR STREQUAL "")
  message(FATAL_ERROR "DUCKDB_SOURCE_DIR is required: the runner discovers .benchmark files under <root>/benchmark")
endif()
if(NOT DEFINED ROOT_DIR OR ROOT_DIR STREQUAL "")
  message(FATAL_ERROR "ROOT_DIR is required: without it the runner writes generated data into the DuckDB source tree")
endif()

set(source_benchmark_dir "${DUCKDB_SOURCE_DIR}/benchmark")
if(NOT IS_DIRECTORY "${source_benchmark_dir}")
  message(FATAL_ERROR "benchmark directory not found in the pinned source: ${source_benchmark_dir}")
endif()

file(MAKE_DIRECTORY "${ROOT_DIR}")

# Re-create the link unconditionally so a moved/renamed source tree cannot leave
# a stale link behind.
if(IS_SYMLINK "${ROOT_DIR}/benchmark")
  file(REMOVE "${ROOT_DIR}/benchmark")
endif()
file(CREATE_LINK "${source_benchmark_dir}" "${ROOT_DIR}/benchmark" SYMBOLIC)
if(NOT IS_DIRECTORY "${ROOT_DIR}/benchmark")
  message(FATAL_ERROR "failed to expose the interpreted benchmarks under ${ROOT_DIR}/benchmark")
endif()

set(out_file "${ROOT_DIR}/dududu_benchmark_smoke.out")
file(REMOVE "${out_file}")

execute_process(
  COMMAND "${BENCHMARK_BIN}" "${BENCHMARK_NAME}" "--root-dir" "${ROOT_DIR}"
          "--out=${out_file}"
  WORKING_DIRECTORY "${ROOT_DIR}"
  OUTPUT_VARIABLE out
  ERROR_VARIABLE err
  RESULT_VARIABLE rc
  TIMEOUT 900)

message(STATUS "benchmark stdout:\n${out}")
if(NOT rc EQUAL 0)
  message(FATAL_ERROR "benchmark runner failed (rc=${rc}) for ${BENCHMARK_NAME}\nstderr:\n${err}")
endif()

if(NOT EXISTS "${out_file}")
  message(FATAL_ERROR "benchmark runner produced no output file: ${out_file}")
endif()
file(READ "${out_file}" result_text)

# The interpreted benchmark's `result` clause is the upstream correctness
# oracle. The runner records a mismatch as INCORRECT in this stream; ERRORS and
# TIMEOUT are produced by the exception path and by the watchdog thread.
if(result_text MATCHES "INCORRECT")
  message(FATAL_ERROR "benchmark result did not match the upstream oracle (${BENCHMARK_NAME}):\n${result_text}\nstderr:\n${err}")
endif()
if(result_text MATCHES "ERROR")
  message(FATAL_ERROR "benchmark raised an error (${BENCHMARK_NAME}):\n${result_text}\nstderr:\n${err}")
endif()
if(result_text MATCHES "TIMEOUT")
  message(FATAL_ERROR "benchmark timed out inside the runner (${BENCHMARK_NAME}):\n${result_text}")
endif()

# A passing run logs one elapsed-seconds value per hot run (5 by default) and
# nothing else, so at least one numeric line must be present. This is what
# distinguishes "the benchmark actually executed" from "the runner started and
# reported success without producing measurements".
string(REGEX MATCHALL "[0-9]+\\.[0-9]+" timings "${result_text}")
list(LENGTH timings timing_count)
if(timing_count LESS 1)
  message(FATAL_ERROR "benchmark produced no timing values (${BENCHMARK_NAME}):\n${result_text}")
endif()

list(GET timings 0 first_timing)
message(STATUS "duckdb benchmark smoke: PASS (${BENCHMARK_NAME}, ${timing_count} runs, first=${first_timing}s)")
message(STATUS "NOTE: this is entry-point evidence only; R0 draws no performance conclusion")

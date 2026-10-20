# DuckDB official benchmark runner: prove the runner is usable and that the
# expected benchmark families (tpch, parquet) are registered.
#
# Invoked as: cmake -DBENCHMARK_BIN=<bin> -P RunDuckdbBenchmarkList.cmake

if(NOT DEFINED BENCHMARK_BIN OR NOT EXISTS "${BENCHMARK_BIN}")
  message(FATAL_ERROR "DuckDB benchmark_runner not found: ${BENCHMARK_BIN}")
endif()

execute_process(COMMAND "${BENCHMARK_BIN}" --list
                OUTPUT_VARIABLE out ERROR_VARIABLE err RESULT_VARIABLE rc)
if(NOT rc EQUAL 0)
  message(FATAL_ERROR "benchmark_runner --list failed (rc=${rc})\nstderr:\n${err}")
endif()

string(REGEX MATCHALL "benchmark/[^\n]+" entries "${out}")
list(LENGTH entries entry_count)
if(entry_count LESS 100)
  message(FATAL_ERROR "benchmark list looks empty (${entry_count} entries)")
endif()

foreach(needle "tpch" "parquet")
  if(NOT out MATCHES "${needle}")
    message(FATAL_ERROR "benchmark list has no '${needle}' benchmarks")
  endif()
endforeach()

message(STATUS "benchmark list: ${entry_count} entries, tpch+parquet present")

# DuckDB shell smoke: one SQL statement plus a Parquet write/read round-trip.
#
# The Parquet round-trip is deliberate: it exercises the local file read path
# (COPY ... TO and a scan of the produced file) that the R1 I/O work will
# target, without turning R0 into a performance measurement.
#
# Invoked as: cmake -DDUCKDB_BIN=<shell> -P RunDuckdbShellSmoke.cmake

if(NOT DEFINED DUCKDB_BIN OR NOT EXISTS "${DUCKDB_BIN}")
  message(FATAL_ERROR "DuckDB shell binary not found: ${DUCKDB_BIN}")
endif()

function(run_sql label sql)
  execute_process(COMMAND "${DUCKDB_BIN}" -c "${sql}"
                  OUTPUT_VARIABLE out ERROR_VARIABLE err RESULT_VARIABLE rc)
  if(NOT rc EQUAL 0)
    message(FATAL_ERROR "shell smoke '${label}' failed (rc=${rc})\nstderr:\n${err}")
  endif()
  message(STATUS "shell smoke '${label}' ok: ${out}")
  set(SHELL_OUT "${out}" PARENT_SCOPE)
endfunction()

run_sql("select-42" "SELECT 42 AS answer;")
if(NOT SHELL_OUT MATCHES "42")
  message(FATAL_ERROR "expected 42 in shell output, got:\n${SHELL_OUT}")
endif()

set(parquet_path "/tmp/dududu_duckdb_smoke.parquet")
file(REMOVE "${parquet_path}")

run_sql("parquet-write"
        "COPY (SELECT range AS i, 'row-' || range AS label FROM range(10000)) TO '${parquet_path}' (FORMAT PARQUET);")

if(NOT EXISTS "${parquet_path}")
  message(FATAL_ERROR "Parquet file was not produced: ${parquet_path}")
endif()

run_sql("parquet-scan" "SELECT COUNT(*) AS rows FROM '${parquet_path}';")
if(NOT SHELL_OUT MATCHES "10000")
  message(FATAL_ERROR "expected 10000 rows from the Parquet scan, got:\n${SHELL_OUT}")
endif()

file(REMOVE "${parquet_path}")
message(STATUS "duckdb shell smoke: PASS")

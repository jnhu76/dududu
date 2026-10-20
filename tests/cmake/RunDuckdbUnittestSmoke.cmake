# DuckDB unittest smoke: run one official SQL logic test through the official
# unittest runner. The runner must actually execute the test file; an exit code
# of 0 with no executed assertions is not accepted, so the output is checked
# for the assertion count as well.
#
# Invoked as:
#   cmake -DUNITTEST_BIN=<bin> -DDUCKDB_SOURCE_DIR=<src>
#         [-DTEST_PATH=test/sql/...] -P RunDuckdbUnittestSmoke.cmake

if(NOT DEFINED UNITTEST_BIN OR NOT EXISTS "${UNITTEST_BIN}")
  message(FATAL_ERROR "DuckDB unittest binary not found: ${UNITTEST_BIN}")
endif()
if(NOT DEFINED DUCKDB_SOURCE_DIR OR NOT IS_DIRECTORY "${DUCKDB_SOURCE_DIR}")
  message(FATAL_ERROR "DuckDB source dir not found: ${DUCKDB_SOURCE_DIR}")
endif()

if(NOT DEFINED TEST_PATH)
  set(TEST_PATH "test/sql/select/test_select_empty_table.test")
endif()

if(NOT EXISTS "${DUCKDB_SOURCE_DIR}/${TEST_PATH}")
  message(FATAL_ERROR "unittest smoke target does not exist: ${DUCKDB_SOURCE_DIR}/${TEST_PATH}")
endif()

execute_process(
  COMMAND "${UNITTEST_BIN}" "${TEST_PATH}"
  WORKING_DIRECTORY "${DUCKDB_SOURCE_DIR}"
  OUTPUT_VARIABLE out
  ERROR_VARIABLE err
  RESULT_VARIABLE rc)

message(STATUS "unittest output:\n${out}")

if(NOT rc EQUAL 0)
  message(FATAL_ERROR "unittest smoke failed (rc=${rc})\nstderr:\n${err}")
endif()

# Catch2 prints "All tests passed (N assertions in M test cases)" or, for a
# single assertion, "(1 assertion in 1 test case)".
if(NOT out MATCHES "All tests passed \\([0-9]+ assertions? in [0-9]+ test cases?\\)")
  message(FATAL_ERROR "unittest produced no executed assertions:\n${out}")
endif()

message(STATUS "duckdb unittest smoke: PASS (${TEST_PATH})")

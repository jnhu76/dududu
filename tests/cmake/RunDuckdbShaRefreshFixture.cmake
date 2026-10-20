# Negative proof for the DuckDB build identity: a moved gitlink can never
# leave the previous binary in place.
#
# Found in review B2: `ExternalProject_Add` with `UPDATE_COMMAND ""` and
# `BUILD_ALWAYS FALSE` is stamp-driven and has no dependency on the submodule
# content, so updating the DuckDB submodule kept the old release running while
# everything looked green. The bridge must therefore (a) bind the binary dir
# and the ExternalProject prefix to the submodule's full HEAD SHA and (b) make
# the parent build re-run CMake when that HEAD moves.
#
# This fixture exercises the real `cmake/DuckDB.cmake` bridge against a stub
# "DuckDB" source that is a real git repository. Only `cmake --build` is used
# after the first configure — an explicit reconfigure would mask a broken
# CMAKE_CONFIGURE_DEPENDS watcher, and the whole point is that the watcher
# alone must notice the move. Both move shapes are covered: a branch commit
# (loose ref changes, HEAD stays a symref) and a detached commit (the HEAD
# file itself changes, the `git submodule update` shape).
#
# Invoked as:
#   cmake -DFIXTURE_ROOT=<scratch dir> -DDUDUDU_CMAKE_DIR=<repo>/cmake \
#         -P RunDuckdbShaRefreshFixture.cmake

if(NOT DEFINED FIXTURE_ROOT OR FIXTURE_ROOT STREQUAL "")
  message(FATAL_ERROR "RunDuckdbShaRefreshFixture requires -DFIXTURE_ROOT=<scratch dir>")
endif()
if(NOT DEFINED DUDUDU_CMAKE_DIR OR NOT IS_DIRECTORY "${DUDUDU_CMAKE_DIR}")
  message(FATAL_ERROR "RunDuckdbShaRefreshFixture requires -DDUDUDU_CMAKE_DIR=<repo>/cmake")
endif()

find_program(FIXTURE_GIT NAMES git REQUIRED)

file(REMOVE_RECURSE "${FIXTURE_ROOT}")
file(MAKE_DIRECTORY "${FIXTURE_ROOT}")

set(src_dir "${FIXTURE_ROOT}/stub-duckdb")
set(parent_dir "${FIXTURE_ROOT}/parent")
set(build_dir "${parent_dir}/build")
set(root_dir "${parent_dir}/root")

# --- The stub "DuckDB" source: a git repo whose identity lands in its products
file(MAKE_DIRECTORY "${src_dir}")
file(WRITE "${src_dir}/CMakeLists.txt"
"cmake_minimum_required(VERSION 3.24)
project(duckdb_sha_stub LANGUAGES NONE)
# The only property under test is the identity: the inner configure stamps the
# current id.txt content into the products the bridge declares as byproducts.
file(READ \"\${CMAKE_CURRENT_SOURCE_DIR}/id.txt\" stub_id)
file(WRITE \"\${CMAKE_BINARY_DIR}/duckdb\" \"\${stub_id}\")
file(WRITE \"\${CMAKE_BINARY_DIR}/test/unittest\" \"stub \${stub_id}\")
file(WRITE \"\${CMAKE_BINARY_DIR}/benchmark/benchmark_runner\" \"stub \${stub_id}\")
")
file(WRITE "${src_dir}/id.txt" "A\n")

function(fixture_git)
  execute_process(COMMAND "${FIXTURE_GIT}" -C "${src_dir}" ${ARGN}
                  RESULT_VARIABLE rc OUTPUT_QUIET ERROR_QUIET)
  if(NOT rc EQUAL 0)
    message(FATAL_ERROR "fixture git step failed (rc=${rc}): git -C ${src_dir} ${ARGN}")
  endif()
endfunction()

fixture_git(init -q -b master)
fixture_git(config user.email dududu-fixture@example.invalid)
fixture_git(config user.name "dududu fixture")
fixture_git(config commit.gpgsign false)

function(fixture_commit)
  fixture_git(add -A)
  fixture_git(commit -q -m "fixture identity")
endfunction()

function(fixture_sha out_var)
  execute_process(COMMAND "${FIXTURE_GIT}" -C "${src_dir}" rev-parse HEAD
                  OUTPUT_VARIABLE sha RESULT_VARIABLE rc
                  OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
  if(NOT rc EQUAL 0)
    message(FATAL_ERROR "fixture cannot resolve stub HEAD")
  endif()
  set(${out_var} "${sha}" PARENT_SCOPE)
endfunction()

fixture_commit()
fixture_sha(sha_a)

# --- The parent project: the real bridge, the real flags, only the source is a stub
file(MAKE_DIRECTORY "${parent_dir}")
file(WRITE "${parent_dir}/CMakeLists.txt"
"cmake_minimum_required(VERSION 3.24)
project(duckdb_sha_fixture LANGUAGES NONE)
set(DUDUDU_BUILD_ROOT \"\${CMAKE_CURRENT_SOURCE_DIR}/root\" CACHE PATH \"\")
set(DUDUDU_DUCKDB_SOURCE_DIR \"\${CMAKE_CURRENT_SOURCE_DIR}/../stub-duckdb\" CACHE PATH \"\")
list(APPEND CMAKE_MODULE_PATH \"${DUDUDU_CMAKE_DIR}\")
include(DuckDB)
dududu_add_duckdb_native()
")

function(fixture_build label)
  execute_process(COMMAND "${CMAKE_COMMAND}" --build "${build_dir}"
                  RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err)
  if(NOT rc EQUAL 0)
    message(FATAL_ERROR "fixture build '${label}' failed (rc=${rc})\n${out}\n${err}")
  endif()
endfunction()

function(expect_content path expected label)
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "fixture '${label}': missing ${path}")
  endif()
  file(READ "${path}" actual)
  string(STRIP "${actual}" actual)
  string(STRIP "${expected}" expected)
  if(NOT actual STREQUAL expected)
    message(FATAL_ERROR "fixture '${label}': ${path} holds '${actual}', expected '${expected}'")
  endif()
endfunction()

# --- Generation A: first build lands in the SHA-scoped directory
execute_process(COMMAND "${CMAKE_COMMAND}" -S "${parent_dir}" -B "${build_dir}" -G Ninja
                RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err)
if(NOT rc EQUAL 0)
  message(FATAL_ERROR "fixture configure failed (rc=${rc})\n${out}\n${err}")
endif()

fixture_build("first build (A)")
set(bin_a "${root_dir}/duckdb-native/${sha_a}")
expect_content("${bin_a}/duckdb" "A" "first build")
expect_content("${bin_a}/test/unittest" "stub A" "first build byproducts")

# A no-op rebuild must not touch the product at all.
file(TIMESTAMP "${bin_a}/duckdb" ts_before)
fixture_build("no-op rebuild")
file(TIMESTAMP "${bin_a}/duckdb" ts_after)
if(NOT ts_before STREQUAL ts_after)
  message(FATAL_ERROR "fixture 'no-op rebuild': the product was rewritten without any identity change")
endif()

# --- Move 1, branch shape: loose ref changes, HEAD stays a symref
file(WRITE "${src_dir}/id.txt" "B\n")
fixture_commit()
fixture_sha(sha_b)
fixture_build("branch move -> B")

set(bin_b "${root_dir}/duckdb-native/${sha_b}")
expect_content("${bin_b}/duckdb" "B" "branch move")
expect_content("${bin_a}/duckdb" "A" "old generation preserved")

# --- Move 2, detached shape: the HEAD file itself changes
file(WRITE "${src_dir}/id.txt" "C\n")
execute_process(COMMAND "${FIXTURE_GIT}" -C "${src_dir}" checkout -q --detach
                RESULT_VARIABLE rc OUTPUT_QUIET ERROR_QUIET)
if(NOT rc EQUAL 0)
  message(FATAL_ERROR "fixture detach failed (rc=${rc})")
endif()
fixture_commit()
fixture_sha(sha_c)
fixture_build("detached move -> C")

set(bin_c "${root_dir}/duckdb-native/${sha_c}")
expect_content("${bin_c}/duckdb" "C" "detached move")
expect_content("${bin_b}/duckdb" "B" "middle generation preserved")
expect_content("${bin_a}/duckdb" "A" "first generation preserved")

if(sha_a STREQUAL sha_b OR sha_b STREQUAL sha_c OR sha_a STREQUAL sha_c)
  message(FATAL_ERROR "fixture sanity: the stub produced colliding SHAs")
endif()

message(STATUS "duckdb sha-refresh fixture: PASS (A=${sha_a} B=${sha_b} C=${sha_c})")

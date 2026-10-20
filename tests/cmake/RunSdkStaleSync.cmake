# Regression for the SDK sync step: an install set that shrinks cannot leave
# stale files in the consumer prefix.
#
# Review B2 chain: `xmake install` never deletes files it no longer produces,
# so staging would keep an artifact from an older Sluice forever, and
# SyncSdk.cmake (which copies everything it finds in staging) would carry it
# into the SDK where the prefix-side prune cannot see it. The fix wipes
# staging before every install; this test pins the sync-side contract that
# makes that fix sound. The wipe itself is proven end-to-end by
# `sluice.sdk.install-wipe`.
#
# Three properties, on scratch directories only:
#   1. a file dropped from the install set disappears from the prefix,
#   2. an unchanged file keeps its mtime (no spurious relink), and
#   3. a changed file carries the new bytes.
#
# Invoked as:
#   cmake -DSYNC_SDK_SCRIPT=<repo>/cmake/SyncSdk.cmake -DFIXTURE_ROOT=<dir> \
#         -P RunSdkStaleSync.cmake

if(NOT DEFINED SYNC_SDK_SCRIPT OR NOT EXISTS "${SYNC_SDK_SCRIPT}")
  message(FATAL_ERROR "RunSdkStaleSync requires -DSYNC_SDK_SCRIPT=<repo>/cmake/SyncSdk.cmake")
endif()
if(NOT DEFINED FIXTURE_ROOT OR FIXTURE_ROOT STREQUAL "")
  message(FATAL_ERROR "RunSdkStaleSync requires -DFIXTURE_ROOT=<scratch dir>")
endif()

file(REMOVE_RECURSE "${FIXTURE_ROOT}")
file(MAKE_DIRECTORY "${FIXTURE_ROOT}")

set(stage_dir "${FIXTURE_ROOT}/stage")
set(sdk_dir "${FIXTURE_ROOT}/sdk")

function(sync label)
  execute_process(COMMAND "${CMAKE_COMMAND}"
                          "-DSTAGE_DIR=${stage_dir}" "-DSDK_DIR=${sdk_dir}"
                          -P "${SYNC_SDK_SCRIPT}"
                  RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err)
  if(NOT rc EQUAL 0)
    message(FATAL_ERROR "stale-sync '${label}': SyncSdk failed (rc=${rc})\n${out}\n${err}")
  endif()
endfunction()

# --- Generation 1: the previous release still installs include/a.h
file(MAKE_DIRECTORY "${stage_dir}/include" "${stage_dir}/lib")
file(WRITE "${stage_dir}/include/a.h" "#pragma once // a, generation 1\n")
file(WRITE "${stage_dir}/include/b.h" "#pragma once // b\n")
file(WRITE "${stage_dir}/lib/libx.a" "archive v1\n")
sync("generation 1")

if(NOT EXISTS "${sdk_dir}/include/a.h")
  message(FATAL_ERROR "stale-sync: generation 1 lost include/a.h from the prefix")
endif()
file(TIMESTAMP "${sdk_dir}/include/b.h" b_mtime)

# --- Generation 2: upstream drops a.h, changes libx.a, leaves b.h alone
file(REMOVE "${stage_dir}/include/a.h")
file(WRITE "${stage_dir}/lib/libx.a" "archive v2\n")
sync("generation 2")

if(EXISTS "${sdk_dir}/include/a.h")
  message(FATAL_ERROR
          "stale-sync: include/a.h was dropped upstream but survived in the consumer prefix")
endif()
if(NOT EXISTS "${sdk_dir}/include/b.h")
  message(FATAL_ERROR "stale-sync: generation 2 lost the untouched include/b.h")
endif()
file(TIMESTAMP "${sdk_dir}/include/b.h" b_mtime_after)
if(NOT b_mtime STREQUAL b_mtime_after)
  message(FATAL_ERROR
          "stale-sync: untouched include/b.h changed mtime — the prefix is no longer stable")
endif()
file(READ "${sdk_dir}/lib/libx.a" archive_bytes)
if(NOT archive_bytes MATCHES "archive v2")
  message(FATAL_ERROR "stale-sync: libx.a did not pick up the new bytes")
endif()

message(STATUS "sdk stale-sync: PASS (shrink removes, unchanged keeps mtime, changed updates)")

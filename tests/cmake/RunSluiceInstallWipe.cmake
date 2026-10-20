# Negative proof for the Sluice SDK install: a staging tree is a pure function
# of the current install, nothing else.
#
# Found in review B2: staging (`build/sluice-stage/<profile>`) was never
# cleaned, `xmake install` never deletes files it no longer produces, and
# SyncSdk.cmake copies everything it finds in staging — so a header removed by
# a future Sluice (or planted by anything else) survived into the consumer SDK
# and past the prefix-side prune. The install step must therefore start from a
# clean staging tree; this test plants a rogue file in the real staging
# directory, rebuilds the SDK chain, and asserts the file is gone from staging
# *and* never reaches the prefix.
#
# Unlike `sluice.sdk.stale-sync` this runs against the real work dir, the real
# xmake install and the real sync step. On a warm build tree the chain is a
# fast no-op xmake run; on a cold tree it performs the full Sluice build.
#
# Invoked as:
#   cmake -DBUILD_DIR=<dududu build tree> -DTARGET=<external project target> \
#         -DSTAGE_DIR=<stage> -DSDK_DIR=<prefix> -P RunSluiceInstallWipe.cmake

if(NOT DEFINED BUILD_DIR OR NOT IS_DIRECTORY "${BUILD_DIR}")
  message(FATAL_ERROR "RunSluiceInstallWipe requires -DBUILD_DIR=<dududu build tree>")
endif()
if(NOT DEFINED TARGET)
  message(FATAL_ERROR "RunSluiceInstallWipe requires -DTARGET=<external project target>")
endif()
if(NOT DEFINED STAGE_DIR OR NOT DEFINED SDK_DIR)
  message(FATAL_ERROR "RunSluiceInstallWipe requires -DSTAGE_DIR=... -DSDK_DIR=...")
endif()

set(rogue_name "zzz_review_rogue_header.hpp")
set(rogue_stage "${STAGE_DIR}/include/${rogue_name}")
set(rogue_sdk "${SDK_DIR}/include/${rogue_name}")

file(WRITE "${rogue_stage}"
     "#pragma once\n// Planted by tests/cmake/RunSluiceInstallWipe.cmake to prove the\n"
     "// install step cannot carry stale staging content into the SDK.\n")

execute_process(COMMAND "${CMAKE_COMMAND}" --build "${BUILD_DIR}" --target "${TARGET}"
                RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err)
if(NOT rc EQUAL 0)
  message(FATAL_ERROR "install-wipe: building '${TARGET}' failed (rc=${rc})\n${out}\n${err}")
endif()

if(EXISTS "${rogue_stage}")
  message(FATAL_ERROR
          "install-wipe: ${rogue_stage} survived the install step — staging is not "
          "wiped before `xmake install`, so content from an older Sluice can never leave")
endif()

if(EXISTS "${rogue_sdk}")
  message(FATAL_ERROR
          "install-wipe: the rogue staging file reached the consumer SDK at ${rogue_sdk}")
endif()

message(STATUS "sluice install-wipe: PASS (planted staging file vanished from stage and SDK)")

# Synchronize an xmake install staging tree into the SDK prefix.
#
# Invoked as a build step by cmake/Sluice.cmake:
#   cmake -DSTAGE_DIR=<dir> -DSDK_DIR=<dir> -P SyncSdk.cmake
#
# Why staging exists: `xmake install` rewrites files unconditionally, so
# installing straight into the prefix would bump the archive mtime on every
# build and force consumers to relink even when nothing changed. Copying with
# copy_if_different keeps the prefix stable. Staging is wiped by the install
# step before xmake runs (see cmake/Sluice.cmake), so the tree this script
# reads is exactly the current version's install set: the stale-file removal
# below is what keeps an old archive/header from surviving a target-set
# change, and the copy cannot smuggle artifacts from an older install.

if(NOT DEFINED STAGE_DIR OR NOT DEFINED SDK_DIR)
  message(FATAL_ERROR "SyncSdk.cmake requires -DSTAGE_DIR=... -DSDK_DIR=...")
endif()

if(NOT IS_DIRECTORY "${STAGE_DIR}")
  message(FATAL_ERROR "SyncSdk: staging dir does not exist: ${STAGE_DIR}")
endif()

file(MAKE_DIRECTORY "${SDK_DIR}")

# 1. Remove prefix files that the fresh install no longer produces.
foreach(subdir include lib)
  if(IS_DIRECTORY "${SDK_DIR}/${subdir}")
    file(GLOB_RECURSE existing RELATIVE "${SDK_DIR}" "${SDK_DIR}/${subdir}/*")
    foreach(rel IN LISTS existing)
      if(NOT EXISTS "${STAGE_DIR}/${rel}")
        file(REMOVE "${SDK_DIR}/${rel}")
        message(STATUS "SyncSdk: removed stale ${rel}")
      endif()
    endforeach()
  endif()
endforeach()

# 2. Copy new/changed files. copy_if_different preserves mtime on identical
#    content, which is what keeps unrelated rebuilds from relinking.
file(GLOB_RECURSE produced RELATIVE "${STAGE_DIR}" "${STAGE_DIR}/*")
foreach(rel IN LISTS produced)
  get_filename_component(dest_dir "${SDK_DIR}/${rel}" DIRECTORY)
  file(MAKE_DIRECTORY "${dest_dir}")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "${STAGE_DIR}/${rel}" "${SDK_DIR}/${rel}"
    RESULT_VARIABLE copy_rc)
  if(NOT copy_rc EQUAL 0)
    message(FATAL_ERROR "SyncSdk: failed to copy ${rel} (rc=${copy_rc})")
  endif()
endforeach()

# 3. Empty directories left behind by removals are harmless, but report the
#    final surface so the build log carries the installed identity.
file(GLOB_RECURSE final_files RELATIVE "${SDK_DIR}" "${SDK_DIR}/*")
list(SORT final_files)
list(LENGTH final_files final_count)
message(STATUS "SyncSdk: ${final_count} files in ${SDK_DIR}")

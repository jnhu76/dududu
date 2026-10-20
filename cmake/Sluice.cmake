# Sluice SDK build bridge (dududu-local).
#
# Sluice owns its xmake build. dududu does NOT re-declare Sluice sources and
# does NOT vendor a second CMake definition of the library. This module only:
#   1. drives `xmake` in an isolated work directory (never inside the submodule),
#   2. installs the public SDK into an ignored prefix via the verified two-call
#      form (`xmake install -o <prefix> sluice_core` / `... sluice_async`),
#   3. exposes imported targets that consume the installed prefix only.
#
# The imported targets below are dududu-local conveniences. Sluice ships no
# CMake package config and does not export CMake targets (llms.txt); naming a
# target `Sluice::...` here must never be read as an upstream export.

include_guard(GLOBAL)

include(ExternalProject)

set(DUDUDU_SLUICE_SOURCE_DIR "${PROJECT_SOURCE_DIR}/third_party/sluice"
    CACHE PATH "Checked-out Sluice submodule (xmake project root)")
set(DUDUDU_BUILD_ROOT "${PROJECT_SOURCE_DIR}/build"
    CACHE PATH "Ignored root for xmake work dirs, SDK prefixes and DuckDB output")

find_program(DUDUDU_XMAKE_EXECUTABLE NAMES xmake REQUIRED
             DOC "xmake executable used to build the Sluice SDK")
find_program(DUDUDU_BASH_EXECUTABLE NAMES bash REQUIRED)

set(DUDUDU_CMAKE_MODULE_DIR "${CMAKE_CURRENT_LIST_DIR}")

# ---------------------------------------------------------------------------
# One xmake profile -> one isolated work dir -> one SDK prefix.
#
# Isolation details that matter:
#   * xmake writes its per-project cache to the *invocation* directory, so the
#     build runs with CWD=<work_dir> and `-P <submodule>`; `.xmake` therefore
#     lands in the ignored work dir and never in the submodule.
#   * `--builddir` keeps objects out of the submodule too.
#   * The two profiles use different work dirs; a profile switch can never
#     reuse the other profile's `.xmake` config (the failure mode Sluice's
#     xmake/uring.lua SLUICE_LIBURING_PROFILE define exists to defend against).
# ---------------------------------------------------------------------------
function(dududu_add_sluice_profile profile_name liburing_enabled)
  if(liburing_enabled)
    set(uring_opt "y")
  else()
    set(uring_opt "n")
  endif()

  set(work_dir "${DUDUDU_BUILD_ROOT}/sluice-work/${profile_name}")
  set(stage_dir "${DUDUDU_BUILD_ROOT}/sluice-stage/${profile_name}")
  set(sdk_dir "${DUDUDU_BUILD_ROOT}/sluice-sdk/${profile_name}")
  set(ep_name "sluice_sdk_${profile_name}")

  file(MAKE_DIRECTORY "${work_dir}")
  # CMake validates IMPORTED_INCLUDE_DIRECTORIES at generate time, which is
  # before the external project has run; create the (empty) prefix skeleton so
  # a clean checkout configures instead of failing on a not-yet-installed SDK.
  file(MAKE_DIRECTORY "${sdk_dir}/include" "${sdk_dir}/lib")

  set(core_archive "${sdk_dir}/lib/libsluice_core.a")
  set(async_archive "${sdk_dir}/lib/libsluice_async.a")

  ExternalProject_Add(${ep_name}
    PREFIX "${DUDUDU_BUILD_ROOT}/ep/${profile_name}"
    SOURCE_DIR "${DUDUDU_SLUICE_SOURCE_DIR}"
    BINARY_DIR "${work_dir}"
    CONFIGURE_COMMAND
      "${DUDUDU_XMAKE_EXECUTABLE}" f
        -P "${DUDUDU_SLUICE_SOURCE_DIR}"
        -m release
        "--liburing=${uring_opt}"
        -y
        # Relative, not absolute. xmake rewrites a relative --builddir against
        # the *project* dir when it stores it, but resolves the stored value
        # against the *invocation* CWD when it builds. With an absolute path
        # those two disagree and objects land in <build>/build/sluice-work/...;
        # "out" is resolved once, against the work dir that is already the CWD.
        "--builddir=out"
    BUILD_COMMAND
      "${DUDUDU_BASH_EXECUTABLE}" -c
        "cd '${work_dir}' && '${DUDUDU_XMAKE_EXECUTABLE}' -y sluice_core && '${DUDUDU_XMAKE_EXECUTABLE}' -y sluice_async"
    INSTALL_COMMAND
      "${DUDUDU_BASH_EXECUTABLE}" -c
        # The staging tree must be a pure function of this install. `xmake
        # install` writes without pruning, so anything left in staging — a
        # header a future Sluice no longer installs, or anything else — would
        # survive here and then ride SyncSdk's copy into the consumer SDK,
        # past the prefix-side prune. Wipe first; the sync step then sees an
        # authoritative install set and can prune the SDK against it.
        # (Review B2: proven by tests `sluice.sdk.install-wipe` and
        # `sluice.sdk.stale-sync`.)
        "cd '${work_dir}' && '${CMAKE_COMMAND}' -E rm -rf '${stage_dir}' && '${DUDUDU_XMAKE_EXECUTABLE}' install -o '${stage_dir}' sluice_core && '${DUDUDU_XMAKE_EXECUTABLE}' install -o '${stage_dir}' sluice_async"
    # BUILD_BYPRODUCTS is deliberately NOT set here: the SDK archives are
    # produced by the `sdk_sync` step below, and a file may have only one
    # producing rule. Declaring them there is what makes Ninja aware that a
    # consumer's link input is about to be regenerated; without a known
    # producer the link edge is evaluated before the install runs and a real
    # archive change never triggers a relink.
    # The build step must run every time: xmake owns the real source->object
    # dependency graph, so re-entering it is what makes an edited Sluice source
    # rebuild. A no-op xmake run plus SyncSdk's copy_if_different keeps the SDK
    # prefix (and therefore consumer link inputs) byte- and mtime-stable.
    BUILD_ALWAYS TRUE
    UPDATE_COMMAND ""
    USES_TERMINAL TRUE
    LOG_CONFIGURE TRUE
    LOG_BUILD TRUE
    LOG_INSTALL TRUE
  )

  ExternalProject_Add_Step(${ep_name} sdk_sync
    COMMAND "${CMAKE_COMMAND}"
            "-DSTAGE_DIR=${stage_dir}"
            "-DSDK_DIR=${sdk_dir}"
            -P "${DUDUDU_CMAKE_MODULE_DIR}/SyncSdk.cmake"
    DEPENDEES install
    BYPRODUCTS "${core_archive}" "${async_archive}"
    ALWAYS TRUE
    COMMENT "Syncing installed Sluice SDK (${profile_name})"
  )

  message(STATUS "Sluice profile '${profile_name}': work=${work_dir} sdk=${sdk_dir} liburing=${uring_opt}")
endfunction()

# ---------------------------------------------------------------------------
# Imported targets over the installed prefix.
# ---------------------------------------------------------------------------
function(dududu_add_sluice_imported_targets profile_name)
  set(sdk_dir "${DUDUDU_BUILD_ROOT}/sluice-sdk/${profile_name}")

  add_library(Sluice_${profile_name}_core STATIC IMPORTED GLOBAL)
  set_target_properties(Sluice_${profile_name}_core PROPERTIES
    IMPORTED_LOCATION "${sdk_dir}/lib/libsluice_core.a"
    INTERFACE_INCLUDE_DIRECTORIES "${sdk_dir}/include"
    INTERFACE_COMPILE_FEATURES cxx_std_20)

  add_library(Sluice_${profile_name}_async STATIC IMPORTED GLOBAL)
  set_target_properties(Sluice_${profile_name}_async PROPERTIES
    IMPORTED_LOCATION "${sdk_dir}/lib/libsluice_async.a"
    INTERFACE_INCLUDE_DIRECTORIES "${sdk_dir}/include"
    INTERFACE_COMPILE_FEATURES cxx_std_20
    INTERFACE_LINK_LIBRARIES "Sluice_${profile_name}_core")

  if(profile_name STREQUAL "liburing")
    # GNU static-archive order: consumer.o -lsluice_async -lsluice_core -luring
    set_property(TARGET Sluice_${profile_name}_async APPEND PROPERTY
                 INTERFACE_LINK_LIBRARIES uring)
  endif()
endfunction()

function(dududu_add_sluice)
  dududu_add_sluice_profile(noliburing FALSE)
  dududu_add_sluice_profile(liburing TRUE)
  dududu_add_sluice_imported_targets(noliburing)
  dududu_add_sluice_imported_targets(liburing)

  # Public names used by experiments and tests.
  add_library(Sluice::core ALIAS Sluice_noliburing_core)
  add_library(Sluice::async ALIAS Sluice_noliburing_async)
  add_library(Sluice::core_uring ALIAS Sluice_liburing_core)
  add_library(Sluice::async_uring ALIAS Sluice_liburing_async)
endfunction()

# Link a target against one SDK flavor and carry the build-order dependency
# on the external project that produces the archives.
#
# LINK_DEPENDS is required, not decorative: CMake adds IMPORTED libraries to
# the link line as *order-only* prerequisites, so a rebuilt archive alone does
# not make Ninja relink a consumer. Naming the archives as link dependencies
# restores the real edge "archive changed -> consumer relinks", which is the
# property R0 has to prove. Header changes are already covered by the
# compiler-generated depfiles.
function(dududu_link_sluice target flavor)
  if(flavor STREQUAL "core")
    target_link_libraries(${target} PRIVATE Sluice::core)
    add_dependencies(${target} sluice_sdk_noliburing)
    set(archives "${DUDUDU_BUILD_ROOT}/sluice-sdk/noliburing/lib/libsluice_core.a")
  elseif(flavor STREQUAL "async")
    target_link_libraries(${target} PRIVATE Sluice::async)
    add_dependencies(${target} sluice_sdk_noliburing)
    set(archives "${DUDUDU_BUILD_ROOT}/sluice-sdk/noliburing/lib/libsluice_async.a"
                 "${DUDUDU_BUILD_ROOT}/sluice-sdk/noliburing/lib/libsluice_core.a")
  elseif(flavor STREQUAL "core_uring")
    target_link_libraries(${target} PRIVATE Sluice::core_uring)
    add_dependencies(${target} sluice_sdk_liburing)
    set(archives "${DUDUDU_BUILD_ROOT}/sluice-sdk/liburing/lib/libsluice_core.a")
  elseif(flavor STREQUAL "async_uring")
    target_link_libraries(${target} PRIVATE Sluice::async_uring)
    add_dependencies(${target} sluice_sdk_liburing)
    set(archives "${DUDUDU_BUILD_ROOT}/sluice-sdk/liburing/lib/libsluice_async.a"
                 "${DUDUDU_BUILD_ROOT}/sluice-sdk/liburing/lib/libsluice_core.a")
  else()
    message(FATAL_ERROR "dududu_link_sluice: unknown flavor '${flavor}'")
  endif()
  set_property(TARGET ${target} APPEND PROPERTY LINK_DEPENDS ${archives})
endfunction()

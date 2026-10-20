# Consumer smoke tests over the installed Sluice SDK.
#
# Every test here consumes installed artifacts only; none of them reaches into a
# submodule source tree.

set(DUDUDU_SLUICE_SDK_NOLIBURING "${DUDUDU_BUILD_ROOT}/sluice-sdk/noliburing")
set(DUDUDU_SLUICE_SDK_LIBURING "${DUDUDU_BUILD_ROOT}/sluice-sdk/liburing")

add_executable(sluice_core_consumer sluice-sdk/core_consumer.cpp)
dududu_link_sluice(sluice_core_consumer core)
add_test(NAME sluice.sdk.core COMMAND sluice_core_consumer)

add_executable(sluice_threadpool_consumer sluice-sdk/threadpool_consumer.cpp)
dududu_link_sluice(sluice_threadpool_consumer async)
add_test(NAME sluice.sdk.async.threadpool COMMAND sluice_threadpool_consumer)

add_executable(sluice_uring_consumer sluice-sdk/uring_consumer.cpp)
dududu_link_sluice(sluice_uring_consumer async_uring)
add_test(NAME sluice.sdk.async.uring COMMAND sluice_uring_consumer)
# Exit 2 is the documented NOT_SUPPORTED outcome (no io_uring in this
# environment). CTest reports it as skipped, never as a pass.
set_tests_properties(sluice.sdk.async.uring PROPERTIES SKIP_RETURN_CODE 2)

add_executable(sluice_uring_absence sluice-sdk/uring_absence_consumer.cpp)
dududu_link_sluice(sluice_uring_absence async)
add_test(NAME sluice.sdk.async.uring-absence COMMAND sluice_uring_absence)

# --- Installed-surface boundary --------------------------------------------
add_test(NAME sluice.sdk.header-boundary
         COMMAND ${CMAKE_COMMAND}
                 -DSDK_DIR=${DUDUDU_SLUICE_SDK_NOLIBURING}
                 -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/VerifySdkBoundary.cmake)

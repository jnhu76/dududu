# Verify the installed Sluice SDK surface: exactly the 11 contracted public
# headers and exactly the two static archives, with no detail/ header leaking
# through the install step.
#
# Invoked as: cmake -DSDK_DIR=<prefix> -P VerifySdkBoundary.cmake

if(NOT DEFINED SDK_DIR OR NOT IS_DIRECTORY "${SDK_DIR}")
  message(FATAL_ERROR "VerifySdkBoundary: SDK_DIR is missing or not a directory: ${SDK_DIR}")
endif()

set(expected_headers
    sluice/async/async_io_context.hpp
    sluice/async/request.hpp
    sluice/async/request_scope.hpp
    sluice/async/threadpool_backend.hpp
    sluice/async/uring_backend.hpp
    sluice/blocking/file.hpp
    sluice/effect.hpp
    sluice/error.hpp
    sluice/file_resource.hpp
    sluice/measurement.hpp
    sluice/result.hpp)

file(GLOB_RECURSE actual_headers RELATIVE "${SDK_DIR}/include"
     "${SDK_DIR}/include/*.hpp")
list(SORT actual_headers)
list(SORT expected_headers)

if(NOT actual_headers STREQUAL expected_headers)
  message(FATAL_ERROR
    "SDK header surface mismatch.\n expected: ${expected_headers}\n actual:   ${actual_headers}")
endif()

foreach(archive libsluice_core.a libsluice_async.a)
  if(NOT EXISTS "${SDK_DIR}/lib/${archive}")
    message(FATAL_ERROR "SDK archive missing: ${SDK_DIR}/lib/${archive}")
  endif()
endforeach()

file(GLOB lib_entries RELATIVE "${SDK_DIR}/lib" "${SDK_DIR}/lib/*")
list(LENGTH lib_entries lib_count)
if(NOT lib_count EQUAL 2)
  message(FATAL_ERROR "SDK lib/ must hold exactly 2 archives, found ${lib_count}: ${lib_entries}")
endif()

# No detail/ or backend seam header may be installed, even transitively.
file(GLOB_RECURSE leaked RELATIVE "${SDK_DIR}" "${SDK_DIR}/include/*detail*")
if(leaked)
  message(FATAL_ERROR "internal headers leaked into the SDK prefix: ${leaked}")
endif()

message(STATUS "SDK boundary OK: 11 headers, 2 archives under ${SDK_DIR}")

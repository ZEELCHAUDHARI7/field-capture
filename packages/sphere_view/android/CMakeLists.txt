# The NDK entry point. Gradle's `externalNativeBuild` points here, and this
# file does exactly two things: find the OpenCV that
# `tools/build_native_mobile.sh` installed for this ABI, and build the shared
# pipeline in `../src/sphere_stitch`.
#
# The pipeline itself is not duplicated here. `src/sphere_stitch/CMakeLists.txt`
# is the single definition, shared by this build, the iOS build and the desktop
# replay build, because Phase 02 §2 requires the harness to run *the exact same
# library* the device runs — same sources, same OpenCV version, same module
# list, differing only in the target triple. A second source list here is how
# that stops being true without anybody noticing.

cmake_minimum_required(VERSION 3.18)
project(sphere_view_native LANGUAGES CXX)

get_filename_component(SPHERE_VIEW_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
set(OPENCV_INSTALL "${SPHERE_VIEW_ROOT}/build/opencv-android/${ANDROID_ABI}")

if(NOT EXISTS "${OPENCV_INSTALL}/sdk/native/jni/OpenCVConfig.cmake")
  # A missing OpenCV is the single most likely thing to go wrong on a fresh
  # clone, and the default cmake error for it ("Could not find a package
  # configuration file provided by OpenCV") sends people to Stack Overflow
  # rather than to the script that would fix it in one command.
  message(FATAL_ERROR
    "OpenCV has not been built for ${ANDROID_ABI}.\n"
    "Run this once, from the package root:\n"
    "    tools/build_native_mobile.sh --android\n"
    "It takes 10-20 minutes the first time and is cached afterwards. Looked "
    "for ${OPENCV_INSTALL}/sdk/native/jni/OpenCVConfig.cmake")
endif()

set(OpenCV_DIR "${OPENCV_INSTALL}/sdk/native/jni")

# The unit tests are a host-executable target; cross-compiled for the NDK they
# would link fine and be unrunnable. `tools/build_native.sh` builds and runs
# them on the desktop, which is where they assert anything.
set(SPHERE_STITCH_BUILD_TESTS OFF CACHE BOOL "" FORCE)

add_subdirectory("${SPHERE_VIEW_ROOT}/src/sphere_stitch" sphere_stitch)

target_link_libraries(sphere_stitch PRIVATE log)
target_link_options(sphere_stitch PRIVATE
    -Wl,--gc-sections
    # Keeps OpenCV's symbols out of the host process's global namespace. The
    # C ABI in sphere_stitch.h is the whole intended surface, and an app that
    # links its own OpenCV — plenty do — must not collide with ours.
    -Wl,--exclude-libs,ALL
    # Mandatory for Google Play as of 2025 (R1). NDK r28 does this by default;
    # stating it means the build is still correct on r27, and means
    # spikes/spike_a_opencv/measure.sh is checking an intent rather than a
    # happy accident.
    -Wl,-z,max-page-size=16384
    -Wl,-z,common-page-size=16384)

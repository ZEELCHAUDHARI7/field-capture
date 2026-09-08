# src/sphere_stitch — the native pipeline, shared by Android, iOS and the
# desktop replay tool.
#
# One target, three consumers. PHASE_02 §2 requires tools/replay to run the
# *same* library the device runs, so this file must stay free of anything
# platform-specific: the Android NDK build, the iOS podspec and the host build
# in tools/build_native.sh all point cmake at this same directory and differ
# only in toolchain and OpenCV_DIR.

cmake_minimum_required(VERSION 3.18)
project(sphere_stitch LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Hide everything that is not explicitly exported. The C ABI in
# sphere_stitch.h is the whole public surface; leaking OpenCV's symbols into
# the host process is how you get a duplicate-symbol collision with whatever
# else the app has linked.
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

# photo and video join the list in Phase 05: cv::createMergeMertens and
# cv::createAlignMTB live in photo, cv::findTransformECC in video. Both were
# already in Spike A's pinned BUILD_LIST (R1) for exactly this stage, so this
# adds no module to the shipped binary — it only stops cmake from linking a
# library it was never told about.
find_package(OpenCV REQUIRED COMPONENTS core imgproc imgcodecs features2d calib3d photo video stitching)

set(SPHERE_STITCH_SOURCES
  sphere_stitch.cpp
  sv_json.cpp
  sv_warnings.cpp
  sv_geometry.cpp
  hdr_fuse.cpp
  registration.cpp
  compositing.cpp
  pole_fill.cpp
  report.cpp
)

# Static on iOS, shared everywhere else, and the reason is `dart:ffi`'s lookup
# rather than a packaging preference. Android resolves the pipeline with
# `DynamicLibrary.open('libsphere_stitch.so')`, so it needs a real .so in the
# APK; iOS uses `DynamicLibrary.process()`, which searches symbols **already in
# the app binary** — App Store rules make a freely-loadable .dylib a
# non-starter — so there the archive is linked into the host with
# `-force_load`. One target, two link shapes, no second source list.
option(SPHERE_STITCH_STATIC "Build a static archive rather than a shared library" OFF)
option(SPHERE_STITCH_BUILD_TESTS "Build the native unit tests" ON)

if(SPHERE_STITCH_STATIC)
  add_library(sphere_stitch STATIC ${SPHERE_STITCH_SOURCES})
else()
  add_library(sphere_stitch SHARED ${SPHERE_STITCH_SOURCES})
endif()

target_include_directories(sphere_stitch PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(sphere_stitch PRIVATE ${OpenCV_LIBS})

# -ffast-math is deliberately NOT set. BundleAdjusterRay runs
# Levenberg-Marquardt, and relaxed IEEE semantics in exactly the code whose
# convergence S1 (< 1.0 px RMS) depends on is not a trade worth making. Spike
# A's config.sh makes the same call for the device build; keep them agreed.
#
# -Werror=switch is load-bearing rather than housekeeping: it is what makes
# `SvWarningCode` a closed set. Phase 12 §5 asks that a new warning cannot ship
# without a message, and the first half of that guarantee is that a code added to
# the enum without a wire name fails the build here. The second half is
# `warning_messages_test.dart`, which reads sv_warnings.h and fails if Dart has no
# sentence for a name this side can emit.
target_compile_options(sphere_stitch PRIVATE -O2 -fno-fast-math -Werror=switch)

if(APPLE AND NOT SPHERE_STITCH_STATIC)
  # The replay tool opens this with dart:ffi via DynamicLibrary.open, which
  # wants a plain .dylib next to the build dir rather than a framework.
  set_target_properties(sphere_stitch PROPERTIES
    MACOSX_RPATH ON
    SUFFIX ".dylib")
endif()

# The §7 unit tests. Built alongside the library and run by
# tools/build_native.sh, so a convention regression fails the build everyone
# already runs rather than a suite someone has to remember to install.
#
# Off for the device builds: an executable is not runnable on the host that
# cross-compiled it, so building one for the NDK or for iOS would cost link
# time to produce something nobody can start. The host build keeps them on and
# is where they are actually asserted.
if(SPHERE_STITCH_BUILD_TESTS)
  add_executable(sphere_stitch_test
    sphere_stitch_test.cpp
    ${SPHERE_STITCH_SOURCES}
  )
  target_link_libraries(sphere_stitch_test PRIVATE ${OpenCV_LIBS})
  target_compile_options(sphere_stitch_test PRIVATE -O2 -fno-fast-math -Werror=switch)
endif()

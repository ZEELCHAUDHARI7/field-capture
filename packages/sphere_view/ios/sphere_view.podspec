#
# The AVFoundation half of the plugin.
#
# Deployment target is iOS 14.0. `isContentAwareDistortionCorrectionSupported`
# — which R2 §8 makes mandatory to switch off, because Apple applies that
# correction "at its discretion" and a variable geometry invalidates a fixed
# intrinsics model — arrived in iOS 14.1, and everything above that is
# availability-guarded rather than required.
#
Pod::Spec.new do |s|
  s.name             = 'sphere_view'
  s.version          = '0.1.0'
  s.summary          = '360x180 spherical panorama capture and stitching.'
  s.description      = <<-DESC
Camera control for spherical panorama capture: measured intrinsics, hard
AE/AWB/AF lock, bracketed capture, and shutter timestamps on the same clock as
the motion stream.
                       DESC
  s.homepage         = 'https://github.com/your-org/sphere_view'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'sphere_view' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'

  # CoreMotion is Phase 07's: CMMotionManager device motion under
  # .xArbitraryCorrectedZVertical. No usage-description key is needed — those
  # gate CMPedometer and CMMotionActivity, not raw device motion.
  s.frameworks = 'AVFoundation', 'CoreMedia', 'CoreVideo', 'CoreImage', 'Accelerate', 'CoreMotion'

  # The native stitch pipeline, OpenCV and all, as one archive per SDK.
  #
  # Built by `tools/build_native_mobile.sh --ios` before `pod install` — a
  # `prepare_command` was considered and rejected: it would put a 20-minute
  # OpenCV build inside `pod install`, where a timeout looks like a broken
  # dependency, and it would run again on every `flutter clean`.
  s.vendored_frameworks = 'Frameworks/sphere_stitch.xcframework'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    # C++, and OpenCV's, so the archive's own dependencies resolve.
    'CLANG_CXX_LIBRARY' => 'libc++',
  }

  # `Classes/SphereStitchSymbols.c` is what keeps `sv_stitch`, `sv_free` and
  # `sv_version` in the binary. Read its header comment before removing it: it
  # looks like dead code and is the only thing standing between this pod and a
  # runtime `Failed to lookup symbol 'sv_stitch'` on a device, after a capture.

  # `z` because OpenCV's core is built against the system zlib (config.sh keeps
  # `BUILD_ZLIB=OFF`, since iOS ships one) and `persistence.cpp` calls into it
  # for compressed FileStorage. Without it the link fails on `_gzopen` and
  # friends, which is a long way from anything this package is about.
  s.libraries = 'c++', 'z'
  s.swift_version = '5.0'
end

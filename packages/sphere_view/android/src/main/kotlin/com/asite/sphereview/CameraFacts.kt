package com.asite.sphereview

import android.graphics.ImageFormat
import android.graphics.Rect
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.os.Build
import android.util.Size
import kotlin.math.abs

/**
 * Reads `CameraCharacteristics` and reports what it found. It computes no
 * intrinsics.
 *
 * That restraint is the design (see `pigeons/camera_api.dart` and
 * `lib/src/camera/intrinsics_resolver.dart`): the derivation of Math §4.1 lives
 * once, in Dart, where it can be unit-tested over synthetic capability sets on
 * a laptop instead of only on the two devices anyone happens to have. What
 * cannot move to Dart is the reading, and that is all this file does.
 */
object CameraFacts {

    /** Two aspect ratios closer than this count as the same aspect. */
    private const val ASPECT_TOLERANCE = 0.02

    /**
     * How long a burst the session will accept when real manual control is
     * present.
     *
     * Unlike iOS's `maxBracketedCapturePhotoCount`, Camera2 imposes no bracket
     * length at all — `captureBurst` takes any list. The binding constraint is
     * the `ImageReader`'s `maxImages`, which this session sizes itself, so this
     * is a policy number rather than a hardware one and is reported as such.
     */
    const val MAX_BURST_LENGTH = 8

    fun listCameras(manager: CameraManager): List<CameraDescriptor> {
        val out = mutableListOf<CameraDescriptor>()
        for (id in manager.cameraIdList) {
            out.add(
                try {
                    describe(manager, id)
                } catch (t: Throwable) {
                    // A camera that cannot be described is reported, not
                    // dropped: §2.1 wants what was skipped to be visible, and a
                    // silently missing camera is the hardest kind to notice.
                    CameraDescriptor(
                        id = id,
                        facing = PlatformCameraFacing.EXTERNAL,
                        availableSizes = emptyList(),
                        focalLengthsMm = emptyList(),
                        supportsBracketing = false,
                        maxBracketCount = 0,
                        hasDistortionModel = false,
                        hardwareLevel = PlatformHardwareLevel.UNKNOWN,
                        hasManualSensor = false,
                        isLogicalMultiCamera = false,
                        excludedReason = "characteristics unreadable: $t",
                    )
                }
            )
        }
        return out
    }

    private fun describe(manager: CameraManager, id: String): CameraDescriptor {
        val c = manager.getCameraCharacteristics(id)
        val caps = c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)?.toList() ?: emptyList()
        val hasManualSensor =
            caps.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR)
        val map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val jpegSizes = map?.getOutputSizes(ImageFormat.JPEG)?.toList() ?: emptyList()

        val aeRange = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
        val aeUsable = aeRange != null && aeRange.upper - aeRange.lower >= 2

        return CameraDescriptor(
            id = id,
            facing =
                when (c.get(CameraCharacteristics.LENS_FACING)) {
                    CameraCharacteristics.LENS_FACING_BACK -> PlatformCameraFacing.BACK
                    CameraCharacteristics.LENS_FACING_FRONT -> PlatformCameraFacing.FRONT
                    else -> PlatformCameraFacing.EXTERNAL
                },
            availableSizes =
                jpegSizes
                    .sortedByDescending { it.width.toLong() * it.height }
                    .map { PlatformSize(it.width.toLong(), it.height.toLong()) },
            focalLengthsMm =
                c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                    ?.map { it.toDouble() } ?: emptyList(),
            // R3 §8: the gate is MANUAL_SENSOR in REQUEST_AVAILABLE_CAPABILITIES,
            // never the hardware-level name — LIMITED devices may or may not
            // have it, and LEGACY never does.
            supportsBracketing = hasManualSensor,
            maxBracketCount =
                when {
                    hasManualSensor -> MAX_BURST_LENGTH.toLong()
                    aeUsable -> 3L
                    else -> 1L
                },
            hasDistortionModel = lensDistortion(c) != null,
            hardwareLevel = hardwareLevel(c),
            hasManualSensor = hasManualSensor,
            isLogicalMultiCamera =
                caps.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA),
            excludedReason = if (jpegSizes.isEmpty()) "no JPEG output sizes" else null,
        )
    }

    /**
     * Everything Math §4.1 derives from, in `preCorrectionActiveArraySize`
     * coordinates and with no arithmetic applied.
     */
    fun intrinsicFacts(
        c: CameraCharacteristics,
        cropRegion: Rect?,
        distortionCorrectionOffRequested: Boolean,
    ): AndroidIntrinsicFacts {
        val physical = c.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
        val pixelArray = c.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)
        val active = c.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
        val preCorrection =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                c.get(CameraCharacteristics.SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE)
            } else {
                // R2 §4, verbatim from AOSP: "For devices that do not support
                // android.distortionCorrection.mode control, the active array
                // must be the same as preCorrectionActiveArraySize." Below API
                // 28 there is no such control, so the two are necessarily equal
                // and the active array is the correct anchor.
                null
            }
        val dcModes =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                c.get(CameraCharacteristics.DISTORTION_CORRECTION_AVAILABLE_MODES)
            } else {
                null
            }

        return AndroidIntrinsicFacts(
            focalLengthMm =
                c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                    ?.firstOrNull()?.toDouble(),
            sensorPhysicalWidthMm = physical?.width?.toDouble(),
            sensorPhysicalHeightMm = physical?.height?.toDouble(),
            pixelArraySize = pixelArray?.let { PlatformSize(it.width.toLong(), it.height.toLong()) },
            preCorrectionActiveArray = preCorrection?.toPlatformRect(),
            activeArray = active?.toPlatformRect(),
            cropRegion = (cropRegion ?: preCorrection ?: active)?.toPlatformRect(),
            // Reported raw, including the all-zero shape R2 saw on Pixel
            // hardware. Judging whether it is usable is the resolver's job, and
            // it is a judgement worth making in one place.
            lensIntrinsicCalibration =
                c.get(CameraCharacteristics.LENS_INTRINSIC_CALIBRATION)?.map { it.toDouble() },
            // Unreordered `[κ1..κ5]`. The R2 permutation to OpenCV's
            // `(k1,k2,p1,p2,k3)` already exists in Dart as
            // `BrownConradyDistortion.fromAndroidLensDistortion`; a second copy
            // here is exactly what android/README.md says not to write.
            lensDistortion = lensDistortion(c)?.map { it.toDouble() },
            distortionCorrectionModeOffRequested = distortionCorrectionOffRequested,
            distortionCorrectionSupportsNonOff =
                dcModes?.any { it != CameraMetadata.DISTORTION_CORRECTION_MODE_OFF } ?: false,
            activeArraysDiffer =
                preCorrection != null && active != null && preCorrection != active,
            // Camera2 exposes no 35 mm equivalent; it would come from the JPEG's
            // own EXIF, and by the time that exists the physics path has already
            // succeeded or the device has told us nothing at all.
            focalLengthIn35mmFilm = null,
        )
    }

    private fun lensDistortion(c: CameraCharacteristics): FloatArray? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            c.get(CameraCharacteristics.LENS_DISTORTION)
        } else {
            @Suppress("DEPRECATION")
            c.get(CameraCharacteristics.LENS_RADIAL_DISTORTION)
        }

    fun hardwareLevel(c: CameraCharacteristics): PlatformHardwareLevel =
        when (c.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)) {
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY ->
                PlatformHardwareLevel.LEGACY
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED ->
                PlatformHardwareLevel.LIMITED
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_FULL ->
                PlatformHardwareLevel.FULL
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_3 ->
                PlatformHardwareLevel.LEVEL3
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL ->
                PlatformHardwareLevel.EXTERNAL
            else -> PlatformHardwareLevel.UNKNOWN
        }

    /**
     * The largest 4:3 size, falling back to the largest of any aspect.
     *
     * §7 pitfall 5 in full: "Do not assume the largest JPEG size is 4:3. Filter
     * by aspect explicitly." A 4:3 stream off a 4:3 array is a pure scale, so
     * no crop term enters the intrinsics; a 16:9 stream is a crop, and ignoring
     * that gives a wrong focal and a panorama that does not close.
     */
    fun largestFourThree(sizes: Array<Size>?): Size? {
        if (sizes == null || sizes.isEmpty()) return null
        val fourThree =
            sizes.filter {
                val longSide = maxOf(it.width, it.height).toDouble()
                val shortSide = minOf(it.width, it.height).toDouble()
                shortSide > 0 && abs(longSide / shortSide - 4.0 / 3.0) < ASPECT_TOLERANCE
            }
        return (if (fourThree.isNotEmpty()) fourThree else sizes.toList())
            .maxByOrNull { it.width.toLong() * it.height }
    }

    fun isFourThree(size: Size): Boolean {
        val longSide = maxOf(size.width, size.height).toDouble()
        val shortSide = minOf(size.width, size.height).toDouble()
        return shortSide > 0 && abs(longSide / shortSide - 4.0 / 3.0) < ASPECT_TOLERANCE
    }

    /**
     * The preview size closest to [targetWidth] with the same aspect as the
     * capture stream.
     *
     * Matching the capture aspect matters for aiming: a preview of a different
     * aspect shows the user a different field of view from the one the shutter
     * will record, and the aim gate is 4°.
     */
    fun previewSize(sizes: Array<Size>?, targetWidth: Int, captureAspect: Double): Size {
        if (sizes == null || sizes.isEmpty()) return Size(1280, 960)
        val matching =
            sizes.filter {
                it.height > 0 && abs(it.width.toDouble() / it.height - captureAspect) < ASPECT_TOLERANCE
            }
        val pool = if (matching.isNotEmpty()) matching else sizes.toList()
        // Prefer the largest size that does not exceed the target, so preview
        // never costs more than §4 budgets for; fall back to the smallest
        // available if everything is larger.
        return pool.filter { it.width <= targetWidth }.maxByOrNull { it.width }
            ?: pool.minByOrNull { it.width }!!
    }

    private fun Rect.toPlatformRect(): PlatformRect =
        PlatformRect(
            left = left.toLong(),
            top = top.toLong(),
            width = width().toLong(),
            height = height().toLong(),
        )
}

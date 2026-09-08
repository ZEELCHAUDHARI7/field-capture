package com.asite.sphereview

import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraMetadata
import android.os.SystemClock

/**
 * Puts `SENSOR_TIMESTAMP` on the same clock as `SensorEvent.timestamp`.
 *
 * Phase 06 §2.5 calls this the highest-consequence detail in the phase, and the
 * reason is arithmetic rather than pedantry: a 10–50 ms pose/frame mismatch is
 * 0.6–3° of rotation error at a realistic 60°/s pan. That is larger than
 * everything Phase 03 works to remove, and it does not present as a clock bug —
 * it presents as a stitcher that will not close a seam.
 *
 * There are exactly two cases, named by `SENSOR_INFO_TIMESTAMP_SOURCE`:
 *
 *  - **REALTIME** — the camera stamps frames with `elapsedRealtimeNanos()`,
 *    which is also the base of `SensorEvent.timestamp`. The two *are* one
 *    clock. The offset is zero, exactly, and estimating it would only add
 *    noise.
 *  - **UNKNOWN** — the camera stamps with `System.nanoTime()`, which is not the
 *    sensor base. The offset is real, is device-specific, and has to be
 *    measured.
 *
 * The measurement is the standard interleaved read: bracket a `nanoTime()`
 * reading between two `elapsedRealtimeNanos()` readings and keep the sample
 * whose bracket was tightest. §2.5 describes this as "sampling both clocks in a
 * tight loop and taking the minimum observed difference"; taking the minimum of
 * a raw difference works only because the read latency is one-sided, whereas
 * keeping the narrowest bracket bounds the error explicitly — and the bound is
 * what gets reported, because the exit criterion is stated in microseconds and
 * an unqualified number could not be checked against it.
 */
class TimestampMapper private constructor(
    val base: PlatformTimestampBase,
    /** Nanoseconds to add to a raw camera timestamp to reach the motion clock. */
    val offsetNs: Long,
    /** Half the narrowest read bracket achieved, in nanoseconds. */
    val uncertaintyNs: Long,
    val note: String,
) {

    companion object {
        /**
         * How many interleaved reads to take. 128 costs well under a
         * millisecond and makes it very likely at least one bracket lands
         * inside a scheduling quantum.
         */
        private const val SAMPLES = 128

        fun forCamera(characteristics: CameraCharacteristics): TimestampMapper {
            val source = characteristics.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE)
            return when (source) {
                CameraMetadata.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME ->
                    TimestampMapper(
                        base = PlatformTimestampBase.ANDROID_REALTIME,
                        offsetNs = 0L,
                        uncertaintyNs = 0L,
                        note =
                            "SENSOR_INFO_TIMESTAMP_SOURCE is REALTIME, so SENSOR_TIMESTAMP is " +
                                "already on elapsedRealtimeNanos() — the same base as " +
                                "SensorEvent.timestamp. No conversion, no estimate, no error.",
                    )

                else -> {
                    val m = measure()
                    TimestampMapper(
                        base = PlatformTimestampBase.ANDROID_MONOTONIC_UNKNOWN,
                        offsetNs = m.offsetNs,
                        uncertaintyNs = m.uncertaintyNs,
                        note =
                            "SENSOR_INFO_TIMESTAMP_SOURCE is " +
                                (if (source == null) "unset" else "UNKNOWN") +
                                ", so SENSOR_TIMESTAMP is on System.nanoTime() and NOT " +
                                "comparable with SensorEvent.timestamp. Offset measured over " +
                                "$SAMPLES interleaved reads: ${m.offsetNs / 1000} µs, narrowest " +
                                "read bracket ${m.windowNs / 1000} µs, spread across samples " +
                                "${m.spreadNs / 1000} µs.",
                    )
                }
            }
        }

        /** Re-measures now, for the §6 stability check. */
        fun measure(): Estimate {
            var bestWindow = Long.MAX_VALUE
            var bestOffset = 0L
            var minOffset = Long.MAX_VALUE
            var maxOffset = Long.MIN_VALUE
            for (i in 0 until SAMPLES) {
                val before = SystemClock.elapsedRealtimeNanos()
                val mono = System.nanoTime()
                val after = SystemClock.elapsedRealtimeNanos()
                val window = after - before
                // Midpoint of the bracket is the best estimate of where the
                // realtime clock stood when nanoTime() was read.
                val offset = (before + after) / 2 - mono
                if (offset < minOffset) minOffset = offset
                if (offset > maxOffset) maxOffset = offset
                if (window < bestWindow) {
                    bestWindow = window
                    bestOffset = offset
                }
            }
            return Estimate(
                offsetNs = bestOffset,
                uncertaintyNs = bestWindow / 2,
                windowNs = bestWindow,
                spreadNs = if (maxOffset >= minOffset) maxOffset - minOffset else 0L,
            )
        }
    }

    /** One offset measurement and the two ways of describing its error. */
    data class Estimate(
        val offsetNs: Long,
        val uncertaintyNs: Long,
        val windowNs: Long,
        val spreadNs: Long,
    )

    /** Converts a raw camera `SENSOR_TIMESTAMP` to motion-clock microseconds. */
    fun toMotionClockUs(sensorTimestampNs: Long): Long = (sensorTimestampNs + offsetNs) / 1000L

    /** The motion clock's current reading, in microseconds. */
    fun motionClockNowUs(): Long = SystemClock.elapsedRealtimeNanos() / 1000L

    /** The camera clock's current reading, in microseconds. */
    fun cameraClockNowUs(): Long =
        when (base) {
            PlatformTimestampBase.ANDROID_REALTIME -> SystemClock.elapsedRealtimeNanos() / 1000L
            else -> System.nanoTime() / 1000L
        }

    fun toInfo(): ClockSyncInfo =
        ClockSyncInfo(
            base = base,
            offsetUs = offsetNs / 1000L,
            uncertaintyUs = uncertaintyNs / 1000L,
            note = note,
        )

    /**
     * A fresh sample for the §6 stability test. On REALTIME this is trivially
     * zero every time — which is the correct answer and worth returning rather
     * than skipping, because "the offset never moved" is exactly what the test
     * is checking.
     */
    fun sample(): ClockOffsetSample {
        val camera = cameraClockNowUs()
        val motion = motionClockNowUs()
        return when (base) {
            PlatformTimestampBase.ANDROID_REALTIME ->
                ClockOffsetSample(
                    cameraClockUs = camera,
                    motionClockUs = motion,
                    offsetUs = 0L,
                    uncertaintyUs = 0L,
                )

            else -> {
                val m = measure()
                ClockOffsetSample(
                    cameraClockUs = camera,
                    motionClockUs = motion,
                    offsetUs = m.offsetNs / 1000L,
                    uncertaintyUs = m.uncertaintyNs / 1000L,
                )
            }
        }
    }
}

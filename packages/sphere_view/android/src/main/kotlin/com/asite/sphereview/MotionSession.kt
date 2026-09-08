package com.asite.sphereview

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sqrt

/**
 * The AHRS half of the plugin: `TYPE_GAME_ROTATION_VECTOR`, plus the gravity
 * and gyroscope readings that go with it.
 *
 * **`GAME_ROTATION_VECTOR`, never `ROTATION_VECTOR`** (Phase 07 §1). The two
 * are identical except that the plain one folds in the geomagnetic field, and
 * indoors that field is bent tens of degrees by rebar, steel studs and lift
 * motors — the failure Math §1.1 rejects the magnetometer to avoid. The game
 * variant is gyro + accelerometer only: bias-corrected, scale-corrected, and
 * blind to steel. Its yaw is relative to wherever the stream started, which is
 * exactly what §1.1 asks for anyway.
 *
 * Like `CameraFacts`, this class reports **raw platform facts and computes no
 * frame conversion**. The Android world frame is Z-up and ours is Y-up, and
 * Phase 07 §2 is explicit that the conversion between them "must be proven by
 * the §5 test, not by derivation" — its own worked derivation produces a
 * determinant −1 reflection that would mirror the panorama. A conversion
 * written here could only ever be tested on the devices in the room; in Dart it
 * is one function pinned by unit tests. So the quaternion crosses the channel
 * exactly as the sensor produced it.
 *
 * The one convention that *is* resolved here is the gravity sign, because it is
 * a fact about what this platform's sensor reads in a known physical pose
 * rather than a piece of geometry. AOSP documents the accelerometer as reading
 * `+9.81` on Z with the device flat on its back — and `TYPE_GRAVITY` shares the
 * accelerometer's coordinate system — so the reported vector points *away* from
 * the earth. iOS reports the opposite sign, so each side normalises to one
 * convention ("unit, away from the earth") and Dart cross-checks the result
 * rather than trusting either.
 */
class MotionSession(
    private val context: Context,
    private val onSample: (PlatformPoseSample) -> Unit,
    private val onError: (String, String) -> Unit,
) {

    private val sensors: SensorManager by lazy {
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    }

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var listener: Listener? = null

    /** Set once the clock base is known and Dart is ready to receive. */
    @Volatile private var streaming = false

    @Volatile private var clockOffsetNs = 0L

    private var sequence = 0L

    /**
     * How long to wait inside [start] for the first sample.
     *
     * The clock base cannot be decided without one — the whole question is what
     * base `SensorEvent.timestamp` is on — so [start] blocks briefly to answer
     * it before returning. It runs on the plugin's operations executor, never
     * on the platform thread.
     */
    private val firstSampleTimeoutMs = 2000L

    /** Reads used to identify the timestamp base. */
    private val clockProbeSamples = 32

    fun capabilities(): PoseCapabilities {
        val gyro = sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
        val accel = sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        val rotation = sensors.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
        val gravity = sensors.getDefaultSensor(Sensor.TYPE_GRAVITY)

        val reason =
            when {
                gyro == null ->
                    "This tablet has no gyroscope, so it cannot track the rotation " +
                        "between shots. A 360° capture is not possible on this device — " +
                        "use one with a gyroscope."
                rotation == null ->
                    "This tablet has a gyroscope but does not provide the fused " +
                        "GAME_ROTATION_VECTOR orientation sensor, which the capture " +
                        "depends on. Use a different device."
                accel == null ->
                    "This tablet has no accelerometer, so the panorama could not be " +
                        "levelled against gravity. Use a different device."
                else -> null
            }

        val detail =
            buildString {
                append("gyroscope=")
                append(gyro?.name ?: "absent")
                append("; game_rotation_vector=")
                append(rotation?.name ?: "absent")
                append("; gravity=")
                append(gravity?.name ?: "absent (falling back to the accelerometer)")
                append("; accelerometer=")
                append(accel?.name ?: "absent")
                if (rotation != null) {
                    append("; minDelay=")
                    append(rotation.minDelay)
                    append("us")
                }
            }

        return PoseCapabilities(
            hasGyroscope = gyro != null,
            hasAccelerometer = accel != null,
            hasFusedRotation = rotation != null,
            hasGravity = gravity != null,
            // The point of GAME_ROTATION_VECTOR. Reported rather than asserted so
            // that a build which reached for TYPE_ROTATION_VECTOR shows up as a
            // recorded fact in the bundle instead of as an unexplained heading
            // error on a site with steel in the walls.
            usesMagnetometer = false,
            frame = PlatformPoseFrame.ANDROID_GAME_ROTATION_VECTOR,
            minDelayUs = (rotation?.minDelay ?: 0).toLong(),
            detail = detail,
            unsupportedReason = reason,
        )
    }

    fun start(samplingPeriodUs: Long): PoseStreamInfo {
        val found = capabilities()
        found.unsupportedReason?.let { throw FlutterError("pose_unsupported", it, found.detail) }
        stop()

        val rotation = sensors.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)!!
        val gravity = sensors.getDefaultSensor(Sensor.TYPE_GRAVITY)
        val accel = sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        val gyro = sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE)!!

        val worker = HandlerThread("sphere-motion").also { it.start() }
        val workerHandler = Handler(worker.looper)
        thread = worker
        handler = workerHandler
        sequence = 0

        val first = CountDownLatch(1)
        val probe = Listener(first)
        listener = probe

        val period = samplingPeriodUs.toInt().coerceAtLeast(0)
        val registered =
            sensors.registerListener(probe, rotation, period, workerHandler) &&
                sensors.registerListener(probe, gyro, period, workerHandler) &&
                // The accelerometer only stands in when there is no fused gravity
                // sensor. Registering both would mean two sources writing the same
                // field at different rates and different smoothness.
                (if (gravity != null) {
                    sensors.registerListener(probe, gravity, period, workerHandler)
                } else {
                    accel != null && sensors.registerListener(probe, accel, period, workerHandler)
                })
        if (!registered) {
            stop()
            throw FlutterError(
                "pose_register_failed",
                "SensorManager refused to register the motion sensors",
                found.detail,
            )
        }

        // Block until one sample has arrived, because the timestamp base cannot
        // be identified without one and every pose in the session is wrong by
        // the difference if it is guessed.
        if (!first.await(firstSampleTimeoutMs, TimeUnit.MILLISECONDS)) {
            stop()
            throw FlutterError(
                "pose_no_samples",
                "the motion sensors were registered but delivered no sample within " +
                    "$firstSampleTimeoutMs ms",
                found.detail,
            )
        }

        val clock = probe.clock()
        clockOffsetNs = clock.offsetNs
        streaming = true

        return PoseStreamInfo(
            frame = PlatformPoseFrame.ANDROID_GAME_ROTATION_VECTOR,
            clock =
                PoseClockInfo(
                    base = clock.base,
                    offsetUs = clock.offsetNs / 1000L,
                    uncertaintyUs = clock.uncertaintyNs / 1000L,
                    note = clock.note,
                ),
            samplingPeriodUs = samplingPeriodUs,
            minDelayUs = rotation.minDelay.toLong(),
            note =
                "TYPE_GAME_ROTATION_VECTOR at ${samplingPeriodUs}us requested " +
                    "(sensor minDelay ${rotation.minDelay}us); up vector from " +
                    (if (gravity != null) "TYPE_GRAVITY" else "TYPE_ACCELEROMETER (no TYPE_GRAVITY)") +
                    "; angular speed from TYPE_GYROSCOPE.",
        )
    }

    fun stop() {
        streaming = false
        listener?.let { sensors.unregisterListener(it) }
        listener = null
        thread?.quitSafely()
        thread = null
        handler = null
    }

    /** What the timestamp probe concluded. */
    private data class ClockFinding(
        val base: PlatformPoseClockBase,
        val offsetNs: Long,
        val uncertaintyNs: Long,
        val note: String,
    )

    /**
     * Collects the three sensors and emits one sample per attitude reading.
     *
     * The attitude sensor drives the rate: gravity and angular speed are
     * *properties of the same instant*, and pairing each attitude with the most
     * recent reading of the other two is the honest way to say so. Emitting on
     * whichever sensor happened to fire last would produce three interleaved
     * streams at three cadences, each carrying two stale fields.
     */
    private inner class Listener(private val firstSample: CountDownLatch) : SensorEventListener {

        private var upX = 0f
        private var upY = 0f
        private var upZ = 1f
        private var haveUp = false
        private var angularSpeed = 0f
        private var reportedUnreliable = false

        // Clock identification. `SensorEvent.timestamp` is documented as
        // `elapsedRealtimeNanos`, and §6 pitfall 1 says the base "varies by
        // device". The two candidates differ by however long the device has
        // slept since boot — hours, typically — so whichever clock reads closest
        // to the event stamp at delivery is the base, by a margin no scheduling
        // jitter can close.
        private var probesTaken = 0
        private var bestRealtimeDeltaNs = Long.MAX_VALUE
        private var bestMonotonicDeltaNs = Long.MAX_VALUE

        override fun onSensorChanged(event: SensorEvent) {
            when (event.sensor.type) {
                Sensor.TYPE_GRAVITY, Sensor.TYPE_ACCELEROMETER -> {
                    // AOSP: flat on its back, the accelerometer reads +9.81 on Z,
                    // and TYPE_GRAVITY shares its coordinate system — so this
                    // vector already points away from the earth and only needs
                    // normalising. iOS reports the opposite sign; each side
                    // normalises to the one convention the wire format declares.
                    val x = event.values[0]
                    val y = event.values[1]
                    val z = event.values[2]
                    val norm = sqrt(x * x + y * y + z * z)
                    if (norm > 1e-6f) {
                        upX = x / norm
                        upY = y / norm
                        upZ = z / norm
                        haveUp = true
                    }
                }

                Sensor.TYPE_GYROSCOPE -> {
                    val x = event.values[0]
                    val y = event.values[1]
                    val z = event.values[2]
                    // A magnitude: frame-invariant, which keeps one more sign
                    // convention off the wire, and the only form the steadiness
                    // gate wants.
                    angularSpeed = sqrt(x * x + y * y + z * z)
                }

                Sensor.TYPE_GAME_ROTATION_VECTOR -> onAttitude(event)
            }
        }

        /**
         * The one asynchronous failure this stream has.
         *
         * A HAL that downgrades the fused orientation to `UNRELIABLE` is saying
         * its own attitude estimate is not trustworthy, and every pose after
         * that point seeds bundle adjustment with a number the sensor has
         * disowned. Reported once per episode — architecture §8, never
         * silently degrade — rather than logged and forgotten.
         */
        override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {
            if (sensor.type != Sensor.TYPE_GAME_ROTATION_VECTOR) return
            val unreliable = accuracy == SensorManager.SENSOR_STATUS_UNRELIABLE
            if (unreliable && !reportedUnreliable && streaming) {
                reportedUnreliable = true
                onError(
                    "pose_unreliable",
                    "the fused orientation sensor reported SENSOR_STATUS_UNRELIABLE, so its " +
                        "attitude estimate should not be trusted. Put the tablet down for a " +
                        "moment to let it re-converge, or move away from strong vibration.",
                )
            } else if (!unreliable) {
                reportedUnreliable = false
            }
        }

        private fun onAttitude(event: SensorEvent) {
            probeClocks(event.timestamp)
            // One probe is enough to *identify* the base, because the two
            // candidates differ by the device's total sleep since boot — hours,
            // against microseconds of read latency. Later probes only tighten
            // the number quoted in the note; the offset itself, when one is
            // needed, comes from `TimestampMapper.measure()`'s own 128 reads.
            firstSample.countDown()
            if (!streaming || !haveUp) return

            val x = event.values[0]
            val y = event.values[1]
            val z = event.values[2]
            // API 18+ supplies the scalar directly, but not every HAL fills the
            // fourth slot. Reconstructing it from a unit-quaternion constraint is
            // exact for the values that are present, and `coerceAtLeast(0)` keeps
            // a sensor that overshoots slightly from producing a NaN.
            val w =
                if (event.values.size >= 4) {
                    event.values[3]
                } else {
                    sqrt((1f - x * x - y * y - z * z).coerceAtLeast(0f))
                }

            onSample(
                PlatformPoseSample(
                    qx = x.toDouble(),
                    qy = y.toDouble(),
                    qz = z.toDouble(),
                    qw = w.toDouble(),
                    upX = upX.toDouble(),
                    upY = upY.toDouble(),
                    upZ = upZ.toDouble(),
                    angularSpeedRadPerSec = angularSpeed.toDouble(),
                    timestampUs = (event.timestamp + clockOffsetNs) / 1000L,
                    sequence = sequence++,
                    accuracy = event.accuracy.toLong(),
                )
            )
        }

        private fun probeClocks(eventTimestampNs: Long) {
            if (probesTaken >= clockProbeSamples) return
            probesTaken++
            val realtime = SystemClock.elapsedRealtimeNanos()
            val monotonic = System.nanoTime()
            bestRealtimeDeltaNs = minOf(bestRealtimeDeltaNs, abs(realtime - eventTimestampNs))
            bestMonotonicDeltaNs = minOf(bestMonotonicDeltaNs, abs(monotonic - eventTimestampNs))
        }

        fun clock(): ClockFinding {
            val realtimeDelta = bestRealtimeDeltaNs
            val monotonicDelta = bestMonotonicDeltaNs
            if (realtimeDelta <= monotonicDelta) {
                return ClockFinding(
                    base = PlatformPoseClockBase.ANDROID_ELAPSED_REALTIME,
                    offsetNs = 0L,
                    uncertaintyNs = 0L,
                    note =
                        "SensorEvent.timestamp is on elapsedRealtimeNanos() — the documented " +
                            "base, and the same one Phase 06 puts camera frames on when " +
                            "SENSOR_INFO_TIMESTAMP_SOURCE is REALTIME. Closest read was " +
                            "${realtimeDelta / 1000L}us from elapsedRealtime against " +
                            "${monotonicDelta / 1000L}us from nanoTime. No conversion, no " +
                            "estimate, no error.",
                )
            }
            // §6 pitfall 1's device. The two clocks diverge by the total time
            // spent asleep since boot, so this is not a rounding difference —
            // every pose in the session would be paired with the wrong frame.
            val estimate = TimestampMapper.measure()
            return ClockFinding(
                base = PlatformPoseClockBase.ANDROID_MONOTONIC_NANO_TIME,
                offsetNs = estimate.offsetNs,
                uncertaintyNs = estimate.uncertaintyNs,
                note =
                    "SensorEvent.timestamp is NOT on elapsedRealtimeNanos(): the closest read " +
                        "was ${monotonicDelta / 1000L}us from System.nanoTime() against " +
                        "${realtimeDelta / 1000L}us from elapsedRealtime, a gap of " +
                        "${max(0L, realtimeDelta - monotonicDelta) / 1000L}us. This is Phase 07 " +
                        "§6 pitfall 1. Samples are shifted by ${estimate.offsetNs / 1000L}us " +
                        "(narrowest read bracket ${estimate.windowNs / 1000L}us) onto the " +
                        "elapsedRealtime base the camera uses.",
            )
        }
    }
}

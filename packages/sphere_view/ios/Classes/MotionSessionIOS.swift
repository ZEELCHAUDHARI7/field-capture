import CoreMotion
import Foundation

/// The AHRS half of the plugin: `CMMotionManager.deviceMotion` under
/// `.xArbitraryCorrectedZVertical`.
///
/// **`.xArbitraryCorrectedZVertical`, never `.xTrueNorthZVertical`** (Phase 07
/// §1). The true-north frames pull in the magnetometer, and indoors that field
/// is bent tens of degrees by rebar, steel studs and lift motors — the failure
/// Math §1.1 rejects the compass to avoid. The arbitrary-X frame is gyro +
/// accelerometer with `Z` locked to vertical and yaw drift-*corrected* (the
/// `Corrected` in the name is Core Motion's own long-term yaw-drift
/// compensation), which is exactly what §1.1 asks for: gravity-locked pitch and
/// roll, and a yaw that means "relative to where the session started".
///
/// Like `CameraSessionIOS`, this reports **raw platform facts and computes no
/// frame conversion**. Apple's reference frame is `Z`-vertical and ours is
/// `Y`-up, and Phase 07 §2 says in as many words that the conversion between
/// them "must be proven by the §5 test, not by derivation" — the doc's own
/// derivation lands on a determinant −1 reflection that would mirror the
/// panorama. The conversion lives in Dart, in one function, pinned by unit
/// tests; the quaternion crosses the channel exactly as Core Motion produced
/// it.
///
/// The one convention resolved here is the gravity sign, because it is a fact
/// about what this platform reads in a known physical pose rather than a piece
/// of geometry: Apple documents `CMDeviceMotion.gravity` as an acceleration
/// vector expressed in the device frame, and with the device flat on its back
/// it reads `(0, 0, −1)` — pointing *toward* the earth, the opposite of
/// Android's `TYPE_GRAVITY`. Negating here leaves Dart with one convention
/// instead of two, and Dart cross-checks the result rather than trusting it.
final class MotionSessionIOS {

    /// Core Motion publishes no accuracy scale, so every sample reports this.
    /// `-1` rather than a fabricated "good", because inventing a quality signal
    /// the platform does not provide is worse than admitting there is none.
    private static let noAccuracy: Int64 = -1

    /// How long to wait inside `start` for the first sample.
    ///
    /// §6 pitfall 2: `CMDeviceMotion` needs 1–2 s to converge after
    /// `startDeviceMotionUpdates`. This wait is not that convergence window —
    /// the Dart-side warm-up owns that — it only blocks until *a* sample has
    /// arrived, so that `startPose` returns having confirmed the stream is
    /// alive rather than having merely asked for it.
    private static let firstSampleTimeout: TimeInterval = 3.0

    private let manager = CMMotionManager()
    private let queue = OperationQueue()

    private let onSample: (PlatformPoseSample) -> Void
    private let onError: (String, String) -> Void

    private var sequence: Int64 = 0

    init(
        onSample: @escaping (PlatformPoseSample) -> Void,
        onError: @escaping (String, String) -> Void
    ) {
        self.onSample = onSample
        self.onError = onError
        // A dedicated serial queue: Core Motion delivers on whatever queue it is
        // handed, and building 100 Hz of samples on `.main` would put that work
        // behind whatever frame the UI is building. Note this is about where the
        // *sample* is built — the `onSample` callback still hops to the platform
        // thread to reach Flutter, because platform channels require it. Do not
        // "simplify" by handing Core Motion `.main` directly, and do not remove
        // the hop on the other side of it.
        queue.name = "sphere.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
    }

    func capabilities() -> PoseCapabilities {
        let hasGyro = manager.isGyroAvailable
        let hasAccel = manager.isAccelerometerAvailable
        let hasDeviceMotion = manager.isDeviceMotionAvailable
        let available = CMMotionManager.availableAttitudeReferenceFrames()
        let hasZVertical = available.contains(.xArbitraryCorrectedZVertical)

        var reason: String?
        if !hasGyro {
            reason =
                "This device has no gyroscope, so it cannot track the rotation between "
                + "shots. A 360° capture is not possible on it — use a device with a "
                + "gyroscope."
        } else if !hasDeviceMotion {
            reason =
                "This device does not provide Core Motion device-motion updates, which "
                + "the capture depends on. Use a different device."
        } else if !hasZVertical {
            reason =
                "This device does not offer the xArbitraryCorrectedZVertical attitude "
                + "reference frame. The alternatives all use the magnetometer, which is "
                + "unusable indoors around steel, so the capture is refused rather than "
                + "run on a heading that rebar can bend."
        } else if !hasAccel {
            reason =
                "This device has no accelerometer, so the panorama could not be levelled "
                + "against gravity. Use a different device."
        }

        return PoseCapabilities(
            hasGyroscope: hasGyro,
            hasAccelerometer: hasAccel,
            hasFusedRotation: hasDeviceMotion,
            // `CMDeviceMotion` always carries `gravity`; there is no separate
            // capability to query, and no device with device motion lacks it.
            hasGravity: hasDeviceMotion,
            // The point of choosing this reference frame over the true-north
            // ones. Reported rather than asserted so that a build which reached
            // for `.xTrueNorthZVertical` shows up as a recorded fact in the
            // bundle instead of as an unexplained heading error on a site.
            usesMagnetometer: false,
            frame: .iosXArbitraryCorrectedZVertical,
            // Core Motion publishes no minimum interval. 10 000 µs is the rate
            // §4 asks for and the rate the hardware sustains; 0 would claim
            // knowledge that does not exist.
            minDelayUs: 0,
            detail:
                "gyroAvailable=\(hasGyro); accelerometerAvailable=\(hasAccel); "
                + "deviceMotionAvailable=\(hasDeviceMotion); "
                + "xArbitraryCorrectedZVertical=\(hasZVertical); "
                + "availableAttitudeReferenceFrames=\(available.rawValue)",
            unsupportedReason: reason
        )
    }

    func start(samplingPeriodUs: Int64) throws -> PoseStreamInfo {
        let found = capabilities()
        if let reason = found.unsupportedReason {
            throw PigeonError(code: "pose_unsupported", message: reason, details: found.detail)
        }
        stop()

        sequence = 0
        manager.deviceMotionUpdateInterval = Double(samplingPeriodUs) / 1_000_000.0

        let first = DispatchSemaphore(value: 0)
        var signalled = false
        let signalLock = NSLock()

        manager.startDeviceMotionUpdates(
            using: .xArbitraryCorrectedZVertical, to: queue
        ) { [weak self] motion, error in
            guard let self = self else { return }
            if let error = error {
                self.onError("pose_stream_failed", error.localizedDescription)
                return
            }
            guard let motion = motion else { return }
            self.emit(motion)
            signalLock.lock()
            if !signalled {
                signalled = true
                first.signal()
            }
            signalLock.unlock()
        }

        if first.wait(timeout: .now() + MotionSessionIOS.firstSampleTimeout) == .timedOut {
            stop()
            throw PigeonError(
                code: "pose_no_samples",
                message:
                    "Core Motion accepted the request but delivered no device-motion sample "
                    + "within \(MotionSessionIOS.firstSampleTimeout) s",
                details: found.detail
            )
        }

        return PoseStreamInfo(
            frame: .iosXArbitraryCorrectedZVertical,
            clock: PoseClockInfo(
                base: .iosSystemUptime,
                // Exactly zero, and not an estimate. `CMDeviceMotion.timestamp`
                // is seconds since boot on `systemUptime`, which is the very
                // clock Phase 06's `TimestampMapper` converts camera sample
                // buffers *onto*. The measured quantity on iOS is the
                // camera→motion offset, and it already lives there; measuring it
                // again here would be measuring the same thing twice and
                // inviting the two answers to disagree.
                offsetUs: 0,
                uncertaintyUs: 0,
                note:
                    "CMDeviceMotion.timestamp is ProcessInfo.systemUptime, the base "
                    + "TimestampMapper already converts CMSampleBuffer presentation "
                    + "timestamps onto. The two are one clock here; the camera side owns the "
                    + "measurement."
            ),
            samplingPeriodUs: samplingPeriodUs,
            minDelayUs: 0,
            note:
                "CMDeviceMotion at \(samplingPeriodUs)us requested via "
                + "deviceMotionUpdateInterval, reference frame "
                + "xArbitraryCorrectedZVertical (no magnetometer); up vector from "
                + "CMDeviceMotion.gravity, negated to point away from the earth; angular "
                + "speed from CMDeviceMotion.rotationRate."
        )
    }

    func stop() {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
    }

    private func emit(_ motion: CMDeviceMotion) {
        let q = motion.attitude.quaternion

        // Apple's `gravity` points toward the earth — flat on its back, a device
        // reads (0, 0, −1). Android's `TYPE_GRAVITY` reads (0, 0, +9.81) in the
        // same pose. Negate and normalise so the wire carries one convention:
        // unit, away from the earth.
        let g = motion.gravity
        let norm = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        let scale = norm > 1e-9 ? -1.0 / norm : 0.0

        let rate = motion.rotationRate
        let speed = (rate.x * rate.x + rate.y * rate.y + rate.z * rate.z).squareRoot()

        onSample(
            PlatformPoseSample(
                qx: q.x,
                qy: q.y,
                qz: q.z,
                qw: q.w,
                upX: g.x * scale,
                upY: g.y * scale,
                upZ: g.z * scale,
                angularSpeedRadPerSec: speed,
                timestampUs: Int64((motion.timestamp * 1e6).rounded()),
                sequence: sequence,
                accuracy: MotionSessionIOS.noAccuracy
            )
        )
        sequence += 1
    }
}

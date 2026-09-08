import CoreMedia
import Foundation
import QuartzCore

/// Puts `CMSampleBuffer` presentation timestamps on the same clock as
/// `CMDeviceMotion.timestamp`.
///
/// §3.5 states the problem in one line — sample buffers are on
/// `CMClockGetHostTimeClock` (`mach_absolute_time`) while `CMDeviceMotion`
/// reports `systemUptime` — and §2.5 states the consequence of getting it
/// wrong: a 10–50 ms pose/frame mismatch is 0.6–3° of rotation error at a
/// realistic 60°/s pan, which is larger than everything Phase 03 works to
/// remove and which presents as a stitcher bug rather than as a clock bug.
///
/// On current iOS the two clocks are the same clock underneath, so the offset
/// is a handful of microseconds of read latency and nothing more. **That is
/// measured here rather than assumed**, for two reasons. It is an undocumented
/// implementation detail, not a contract — Apple documents `systemUptime` as
/// "the amount of time the system has been awake since the last time it was
/// restarted" and documents the host clock separately, and nothing promises
/// they share an epoch on some future device or on a platform variant. And the
/// exit criterion is stated as ±2 ms of stability over 60 s, which is a claim
/// about a measurement; asserting equality would leave nothing to check.
final class TimestampMapper {

    /// How many interleaved reads to take. Cheap — the whole loop is well under
    /// a millisecond — and enough that one bracket usually lands inside a
    /// scheduling quantum.
    private static let sampleCount = 128

    /// Microseconds to add to a host-clock timestamp to reach the motion clock.
    private(set) var offsetUs: Int64

    /// Half the narrowest read bracket achieved, in microseconds.
    private(set) var uncertaintyUs: Int64

    private(set) var note: String

    init() {
        let estimate = TimestampMapper.measure()
        offsetUs = estimate.offsetUs
        uncertaintyUs = estimate.uncertaintyUs
        note =
            "CMSampleBuffer presentation timestamps are on CMClockGetHostTimeClock; "
            + "CMDeviceMotion.timestamp is on ProcessInfo.systemUptime. Offset measured over "
            + "\(TimestampMapper.sampleCount) interleaved reads: \(estimate.offsetUs) µs, "
            + "narrowest read bracket \(estimate.windowUs) µs, spread across samples "
            + "\(estimate.spreadUs) µs. A near-zero offset is the expected result on current "
            + "iOS — the two are the same underlying clock — but it is measured, not assumed."
    }

    struct Estimate {
        let offsetUs: Int64
        let uncertaintyUs: Int64
        let windowUs: Int64
        let spreadUs: Int64
    }

    /// Brackets a `systemUptime` read between two host-clock reads and keeps the
    /// sample whose bracket was tightest, which bounds the error explicitly
    /// instead of hoping the two reads were adjacent.
    static func measure() -> Estimate {
        var bestWindow = Double.greatestFiniteMagnitude
        var bestOffset = 0.0
        var minOffset = Double.greatestFiniteMagnitude
        var maxOffset = -Double.greatestFiniteMagnitude

        for _ in 0..<sampleCount {
            let before = hostTimeSeconds()
            let motion = ProcessInfo.processInfo.systemUptime
            let after = hostTimeSeconds()
            let window = after - before
            let offset = (before + after) / 2 - motion
            minOffset = min(minOffset, offset)
            maxOffset = max(maxOffset, offset)
            if window < bestWindow {
                bestWindow = window
                bestOffset = offset
            }
        }

        // `offset` above is host − motion, i.e. how far ahead the host clock
        // reads. To move a host timestamp onto the motion clock, subtract it.
        return Estimate(
            offsetUs: Int64((-bestOffset * 1e6).rounded()),
            uncertaintyUs: Int64((bestWindow / 2 * 1e6).rounded()),
            windowUs: Int64((bestWindow * 1e6).rounded()),
            spreadUs: Int64(((maxOffset - minOffset) * 1e6).rounded())
        )
    }

    /// The host clock's current reading in seconds, via the same clock the
    /// capture pipeline stamps buffers with.
    static func hostTimeSeconds() -> Double {
        CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }

    /// Converts a sample-buffer presentation timestamp to motion-clock
    /// microseconds.
    func toMotionClockUs(_ time: CMTime) -> Int64 {
        guard time.isValid && !time.seconds.isNaN else { return 0 }
        return Int64((time.seconds * 1e6).rounded()) + offsetUs
    }

    /// Converts a host-clock instant in seconds, for the callbacks that report
    /// one rather than a `CMTime`.
    func toMotionClockUs(hostSeconds: Double) -> Int64 {
        Int64((hostSeconds * 1e6).rounded()) + offsetUs
    }

    func toInfo() -> ClockSyncInfo {
        ClockSyncInfo(
            base: .iosHostTime,
            offsetUs: offsetUs,
            uncertaintyUs: uncertaintyUs,
            note: note
        )
    }

    /// A fresh sample for the §6 stability test.
    func sample() -> ClockOffsetSample {
        let estimate = TimestampMapper.measure()
        return ClockOffsetSample(
            cameraClockUs: Int64((TimestampMapper.hostTimeSeconds() * 1e6).rounded()),
            motionClockUs: Int64((ProcessInfo.processInfo.systemUptime * 1e6).rounded()),
            offsetUs: estimate.offsetUs,
            uncertaintyUs: estimate.uncertaintyUs
        )
    }
}

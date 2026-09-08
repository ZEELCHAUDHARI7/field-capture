import AVFoundation
import Flutter
import Foundation
import Metal
import UIKit

/// Plugin entry point: wires the generated host API to a [CameraSessionIOS] and
/// the Flutter callbacks back to Dart.
///
/// Two threading rules hold throughout.
///
/// 1. **Camera work never runs on the platform thread.** Every host method
///    below blocks — on a metering sweep, on a `setExposureModeCustom`
///    completion handler, on a bracket's photos arriving — so all of it goes to
///    one serial queue. Serialising also means two `captureBracket` calls can
///    never interleave, which is how "never touch the session between requests"
///    (§7 pitfall 1) becomes a guarantee rather than a hope.
/// 2. **Replies and Flutter callbacks are posted to the main thread.**
public class SphereViewPlugin: NSObject, FlutterPlugin, SphereCameraHostApi, SpherePoseHostApi {

    private let operations = DispatchQueue(label: "sphere.camera.ops")

    /// The pose stream's own queue. `startPose` blocks until the first
    /// device-motion sample arrives, and queueing that behind a metering sweep
    /// or a bracket would make two independent subsystems wait on each other
    /// for no reason. §6 pitfall 5's "the pose history is continuous" is the
    /// same independence stated from the other side.
    private let poseOperations = DispatchQueue(label: "sphere.pose.ops")

    private let thermal = ThermalMonitor()
    private var flutterApi: SphereCameraFlutterApi?
    private var poseFlutterApi: SpherePoseFlutterApi?
    private var session: CameraSessionIOS?
    private var motion: MotionSessionIOS?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = SphereViewPlugin()
        let messenger = registrar.messenger()
        let flutterApi = SphereCameraFlutterApi(binaryMessenger: messenger)
        plugin.flutterApi = flutterApi

        // Phase 07 sent these straight from Core Motion's serial queue, on the
        // premise that `FlutterBasicMessageChannel.sendMessage` is thread-safe.
        // It is not — platform channels are platform-thread-only on both sides.
        // Android says so loudly (`@UiThread` killed the process on the first
        // sample); iOS corrupts the engine's message queue quietly instead,
        // which is the worse of the two. Hopped here for the same reason as
        // every other callback below.
        //
        // Nothing downstream can tell: a pose lands in `PoseBuffer` under its
        // own `timestampUs` and is read back by SLERP at the shutter timestamp,
        // so arrival time is not an input. Order and completeness are, and a
        // serial queue dispatching async to main preserves both.
        let poseFlutterApi = SpherePoseFlutterApi(binaryMessenger: messenger)
        plugin.poseFlutterApi = poseFlutterApi
        plugin.motion = MotionSessionIOS(
            onSample: { sample in
                DispatchQueue.main.async { poseFlutterApi.onPoseSample(sample: sample) { _ in } }
            },
            onError: { code, message in
                DispatchQueue.main.async {
                    poseFlutterApi.onPoseError(code: code, message: message) { _ in }
                }
            }
        )
        SpherePoseHostApiSetup.setUp(binaryMessenger: messenger, api: plugin)
        plugin.session = CameraSessionIOS(
            textures: registrar.textures(),
            onPreviewFrame: { timestampUs in
                DispatchQueue.main.async { flutterApi.onFrameAvailable(timestampUs: timestampUs) { _ in } }
            },
            onAsyncError: { code, message in
                DispatchQueue.main.async { flutterApi.onError(code: code, message: message) { _ in } }
            },
            onInterruption: { interrupted, reason in
                DispatchQueue.main.async {
                    flutterApi.onSessionInterrupted(interrupted: interrupted, reason: reason) { _ in }
                }
            }
        )
        plugin.thermal.start { state in
            DispatchQueue.main.async { flutterApi.onThermalStateChanged(state: state) { _ in } }
        }
        SphereCameraHostApiSetup.setUp(binaryMessenger: messenger, api: plugin)
        registrar.publish(plugin)
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        thermal.stop()
        operations.async { [session] in session?.close() }
        poseOperations.async { [motion] in motion?.stop() }
    }

    /// Runs `block` off the platform thread and replies on it.
    ///
    /// A thrown `PigeonError` keeps its code; anything else is wrapped, because
    /// a camera failure that reaches Dart untyped is a failure nobody can
    /// branch on.
    private func run<T>(
        _ code: String,
        _ completion: @escaping (Result<T, Error>) -> Void,
        _ block: @escaping () throws -> T
    ) {
        operations.async {
            let outcome: Result<T, Error>
            do {
                outcome = .success(try block())
            } catch let error as PigeonError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(
                    PigeonError(
                        code: code, message: error.localizedDescription,
                        details: String(describing: error)))
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    private func requireSession() throws -> CameraSessionIOS {
        guard let session = session else {
            throw PigeonError(code: "not_open", message: "the plugin is not attached", details: nil)
        }
        return session
    }

    // MARK: - SphereCameraHostApi

    func listCameras(completion: @escaping (Result<[CameraDescriptor], Error>) -> Void) {
        run("list_cameras_failed", completion) { try self.requireSession().listCameras() }
    }

    func open(
        cameraId: String,
        format: CaptureFormatRequest,
        completion: @escaping (Result<CameraOpenResult, Error>) -> Void
    ) {
        run("open_failed", completion) {
            try self.requireSession().open(cameraId: cameraId, request: format)
        }
    }

    func attachPreview(completion: @escaping (Result<Int64, Error>) -> Void) {
        run("attach_preview_failed", completion) { try self.requireSession().attachPreview() }
    }

    func detachPreview(completion: @escaping (Result<Void, Error>) -> Void) {
        run("detach_preview_failed", completion) { try self.requireSession().detachPreview() }
    }

    func meterAndLock(
        durationSeconds: Double, completion: @escaping (Result<MeteringResult, Error>) -> Void
    ) {
        run("meter_failed", completion) {
            try self.requireSession().meterAndLock(durationSeconds: durationSeconds)
        }
    }

    func unlock(completion: @escaping (Result<Void, Error>) -> Void) {
        run("unlock_failed", completion) { try self.requireSession().unlock() }
    }

    func captureBracket(
        evBiases: [Double],
        outputDirectory: String,
        namePrefix: String,
        completion: @escaping (Result<CaptureResponse, Error>) -> Void
    ) {
        run("capture_failed", completion) {
            try self.requireSession().captureBracket(
                evBiases: evBiases, outputDirectory: outputDirectory, namePrefix: namePrefix)
        }
    }

    func thermalState(completion: @escaping (Result<PlatformThermalState, Error>) -> Void) {
        run("thermal_failed", completion) { self.thermal.current }
    }

    func sampleClockOffset(completion: @escaping (Result<ClockOffsetSample, Error>) -> Void) {
        run("clock_sample_failed", completion) { try self.requireSession().sampleClockOffset() }
    }

    /// Phase 11 §2's EXIF `Make`/`Model`.
    ///
    /// `utsname.machine` rather than `UIDevice.model`, which returns the
    /// useless "iPad" for every iPad ever made. The identifier ("iPad14,3") is
    /// what actually distinguishes the hardware, and it is the form a
    /// capability question gets answered against — the marketing name needs a
    /// lookup table that is stale the week after every launch.
    func deviceIdentity(completion: @escaping (Result<DeviceIdentity, Error>) -> Void) {
        run("device_identity_failed", completion) {
            var info = utsname()
            uname(&info)
            // Decoded from the raw bytes rather than through `String(cString:)`
            // or `String(validatingUTF8:)`, both of which are deprecated in
            // Swift 6 and would make the plugin build with warnings in a
            // consuming app — which is somebody else's build log, not ours.
            let identifier = withUnsafeBytes(of: &info.machine) { raw -> String in
                let bytes = raw.prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }
            return DeviceIdentity(
                make: "Apple",
                model: identifier,
                osVersion: "iOS \(UIDevice.current.systemVersion)"
            )
        }
    }

    /// Phase 11 §3.1's texture ceiling, on the Metal side.
    ///
    /// Metal has no `GL_MAX_TEXTURE_SIZE` to read; the limit is a property of
    /// the GPU family and Apple publishes it as a table. Every Metal-capable
    /// iOS device supports at least 8192, and everything from the A11 (family
    /// `apple4`) onward supports 16384 — so unlike Android, iOS is essentially
    /// never the device that turns a panorama into a black sphere. The number
    /// is still reported rather than assumed, because "essentially never" is
    /// how a black sphere ends up shipping.
    func maxTextureSize(completion: @escaping (Result<Int64, Error>) -> Void) {
        run("max_texture_size_failed", completion) {
            guard let device = MTLCreateSystemDefaultDevice() else { return 0 }
            if device.supportsFamily(.apple4) { return 16384 }
            return 8192
        }
    }

    func totalPhysicalMemoryMb(completion: @escaping (Result<Int64, Error>) -> Void) {
        run("memory_probe_failed", completion) {
            Int64(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        }
    }

    /// The stitch's pre-flight check (Phase 10 §4).
    ///
    /// `os_proc_available_memory` reports how much this process may still
    /// allocate before jetsam kills it — which on iOS is the only warning
    /// there is. There is no memory-pressure exception to catch and no chance
    /// to drop a tier once the limit is hit; the process simply stops
    /// existing, and the user sees the app disappear mid-stitch. So the
    /// question has to be asked before the allocation, not after it fails.
    ///
    /// It is deliberately *not* the tier decision. The tier comes from total
    /// physical memory, because this number moves between runs and a
    /// resolution that moves with it would make two stitches of the same
    /// bundle on the same iPad produce different-sized panoramas.
    ///
    /// Available since iOS 13; below that there is no honest answer, so it
    /// says so rather than guessing.
    func availableProcessMemoryMb(completion: @escaping (Result<Int64, Error>) -> Void) {
        run("memory_probe_failed", completion) {
            if #available(iOS 13.0, *) {
                return Int64(os_proc_available_memory() / (1024 * 1024))
            }
            return Int64(-1)
        }
    }

    /// Phase 12 §3's drain-per-station measurement.
    ///
    /// `UIDevice.batteryLevel` is only valid once monitoring is enabled, and it
    /// returns `-1` when it is not — which is exactly the value this API uses for
    /// "will not say", so a caller cannot tell a disabled monitor from a device
    /// that declines. Monitoring is therefore enabled here and left on: it costs
    /// nothing measurable, and turning it off again would break a second call a
    /// station later, which is the only way this number is ever used.
    ///
    /// iOS reports in steps of 5% on some devices, so one station's drain is
    /// below the quantisation. The matrix measures across a run and divides.
    func batteryPercent(completion: @escaping (Result<Int64, Error>) -> Void) {
        run("battery_probe_failed", completion) {
            let device = UIDevice.current
            if !device.isBatteryMonitoringEnabled {
                device.isBatteryMonitoringEnabled = true
            }
            let level = device.batteryLevel
            guard level >= 0 else { return Int64(-1) }
            return Int64((level * 100).rounded())
        }
    }

    func close(completion: @escaping (Result<Void, Error>) -> Void) {
        run("close_failed", completion) { try self.requireSession().close() }
    }

    // MARK: - SpherePoseHostApi

    /// The pose half of `run`, on its own queue.
    private func runPose<T>(
        _ code: String,
        _ completion: @escaping (Result<T, Error>) -> Void,
        _ block: @escaping (MotionSessionIOS) throws -> T
    ) {
        poseOperations.async {
            let outcome: Result<T, Error>
            do {
                guard let motion = self.motion else {
                    throw PigeonError(
                        code: "not_attached", message: "the plugin is not attached", details: nil)
                }
                outcome = .success(try block(motion))
            } catch let error as PigeonError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(
                    PigeonError(
                        code: code, message: error.localizedDescription,
                        details: String(describing: error)))
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    func poseCapabilities(completion: @escaping (Result<PoseCapabilities, Error>) -> Void) {
        runPose("pose_capabilities_failed", completion) { $0.capabilities() }
    }

    func startPose(
        samplingPeriodUs: Int64, completion: @escaping (Result<PoseStreamInfo, Error>) -> Void
    ) {
        runPose("pose_start_failed", completion) {
            try $0.start(samplingPeriodUs: samplingPeriodUs)
        }
    }

    func stopPose(completion: @escaping (Result<Void, Error>) -> Void) {
        runPose("pose_stop_failed", completion) { $0.stop() }
    }
}

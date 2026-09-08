import AVFoundation
import CoreMedia
import CoreVideo
import Flutter
import ImageIO
import Foundation
import simd

/// One `AVCaptureSession`: open, probe intrinsics, meter, lock, bracket, close.
///
/// Three R3/R2 findings shape almost every decision below, so they are stated
/// once here rather than repeated at each site:
///
/// 1. **Neither iOS bracket type locks focus or white balance.** Confirmed
///    against Apple's own AVCamManual-Swift sample: bracket construction sets
///    exposure values and nothing else. So focus and white balance are locked
///    explicitly, *before* any bracket is built. Forgetting this does not fail
///    — it shows up much later as colour and focus banding across the panorama,
///    and looks like a stitcher problem.
/// 2. **`maxBracketedCapturePhotoCount` is not a fixed number.** Apple
///    documents it as varying with `sessionPreset` and `activeFormat` and
///    publishes no per-device table, so it is queried at runtime after the
///    format is settled, and there is a defined fallback below it.
/// 3. **Every distortion correction must be off.** Apple's content-aware
///    correction is applied "at the photo output's discretion" — variably,
///    per frame, depending on content — which invalidates any fixed intrinsics
///    model. Modelling distortion ourselves is the entire point of measuring
///    intrinsics, so the two cannot both be on.
///
/// Every method blocks and must be called off the delegate queues.
final class CameraSessionIOS: NSObject {

    // MARK: - constants

    /// How long to watch the video output for the tier-2 intrinsics
    /// attachment before concluding it is not coming.
    private static let intrinsicProbeSeconds = 1.5

    /// Preview target width, per §4.
    private static let defaultPreviewWidth = 1280

    /// Where in the observed exposure distribution to lock (§2.3 step 3).
    /// Interiors are right-skewed by a few bright windows; a mean meters for
    /// the windows and crushes the interior, and a percentile does not.
    private static let exposurePercentile = 0.65

    /// The longest exposure the bracket will lengthen *to*, ~1/60 s — or the
    /// base exposure when metering already chose something longer in a dim
    /// interior, since clamping the 0 EV frame to satisfy a rule about the
    /// +2 EV frame would trade the session's noise floor for nothing.
    private static let motionBlurLimitSeconds = 1.0 / 60.0

    // MARK: - dependencies

    private let textures: FlutterTextureRegistry

    /// Runs `block` on the platform (main) thread and returns its value.
    ///
    /// Safe to block here: the Pigeon entry points hand work to the operations
    /// queue and reply with `DispatchQueue.main.async`, so the platform thread
    /// is never itself waiting on this one. Called from the platform thread it
    /// runs inline, because `DispatchQueue.main.sync` from main deadlocks.
    private func onPlatformThread<T>(_ block: () -> T) -> T {
        if Thread.isMainThread { return block() }
        return DispatchQueue.main.sync(execute: block)
    }
    private let onPreviewFrame: (Int64) -> Void
    private let onAsyncError: (String, String) -> Void
    private let onInterruption: (Bool, String) -> Void

    private let videoQueue = DispatchQueue(label: "sphere.camera.video")

    // MARK: - session state

    private var session: AVCaptureSession?
    private var device: AVCaptureDevice?
    private var photoOutput: AVCapturePhotoOutput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var previewTexture: PreviewTexture?
    private var textureId: Int64?
    private var mapper: TimestampMapper?
    private var observers: [NSObjectProtocol] = []

    private var captureSize = PlatformSize(width: 0, height: 0)
    private var previewSize = PlatformSize(width: 0, height: 0)
    private var computeStatistics = false
    private var bracketMode: PlatformBracketMode = .photoBracket
    private var maxBracketCount = 1

    /// Guarded by `intrinsicsLock`; written from the video delegate queue.
    private let intrinsicsLock = NSLock()
    private var observedIntrinsicMatrix: [Double]?
    private var observedIntrinsicReference: PlatformSize?
    private var intrinsicAttachmentArrived = false
    private var framesSeen = 0

    /// The exposure the whole session is frozen at.
    private var baseDuration = CMTime.zero
    private var baseISO: Float = 0
    private var lockQuality: PlatformLockQuality = .unlocked
    private var isLocked = false

    init(
        textures: FlutterTextureRegistry,
        onPreviewFrame: @escaping (Int64) -> Void,
        onAsyncError: @escaping (String, String) -> Void,
        onInterruption: @escaping (Bool, String) -> Void
    ) {
        self.textures = textures
        self.onPreviewFrame = onPreviewFrame
        self.onAsyncError = onAsyncError
        self.onInterruption = onInterruption
        super.init()
    }

    // MARK: - enumeration

    func listCameras() -> [CameraDescriptor] {
        var types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .builtInTelephotoCamera, .builtInUltraWideCamera,
            .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera,
        ]
        if #available(iOS 15.4, *) { types.append(.builtInLiDARDepthCamera) }

        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified)

        return discovered.devices.map { device in
            let format = device.activeFormat
            let sizes = photoSizes(for: device).map {
                PlatformSize(width: Int64($0.width), height: Int64($0.height))
            }
            // An indication only. R3 §4 is explicit that
            // `maxBracketedCapturePhotoCount` varies with `sessionPreset` and
            // `activeFormat`, and this output is attached to neither — so the
            // number here is what the class defaults to, not what this camera
            // will grant. The authoritative query happens in `open()`, after the
            // format is settled, and that is the one `CameraOpenResult` carries
            // and the exposure controller sizes the bracket against.
            let probe = AVCapturePhotoOutput()
            let bracketCount = probe.maxBracketedCapturePhotoCount

            return CameraDescriptor(
                id: device.uniqueID,
                facing: {
                    switch device.position {
                    case .back: return .back
                    case .front: return .front
                    default: return .external
                    }
                }(),
                availableSizes: sizes,
                // AVFoundation does not publish focal length in millimetres.
                // The horizontal field of view is the equivalent information
                // and the thing §2.1's ultra-wide exclusion actually needs — a
                // wider field means a shorter lens — so it is reported here and
                // the Dart selector treats it as a proportional stand-in.
                focalLengthsMm: [Double(format.videoFieldOfView) > 0 ? 1.0 / tan(Double(format.videoFieldOfView) * .pi / 360.0) : 0],
                supportsBracketing: device.isExposureModeSupported(.custom) && bracketCount >= 2,
                maxBracketCount: Int64(max(bracketCount, 1)),
                hasDistortionModel: probe.isCameraCalibrationDataDeliverySupported,
                hardwareLevel: .unknown,
                hasManualSensor: device.isExposureModeSupported(.custom),
                isLogicalMultiCamera: device.isVirtualDevice,
                excludedReason: sizes.isEmpty ? "no photo dimensions reported" : nil
            )
        }
    }

    // MARK: - open

    func open(cameraId: String, request: CaptureFormatRequest) throws -> CameraOpenResult {
        close()

        // Before anything else. Without authorisation an AVCaptureSession does
        // not fail — it runs and delivers black frames, which is far worse than
        // an error here: the metering sweep would meter black, the grey-card
        // test would measure a uniform zero and *pass*, and the first sign of
        // trouble would be a panorama of nothing.
        try requireCameraAuthorization()

        guard let device = findDevice(uniqueID: cameraId) else {
            throw PigeonError(code: "no_such_camera", message: "no camera with id \(cameraId)", details: nil)
        }
        self.device = device
        computeStatistics = request.computeFrameStatistics

        var warnings: [String] = []

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            throw PigeonError(code: "input_failed", message: "cannot add \(cameraId) as an input", details: nil)
        }
        session.addInput(input)

        let photoOutput = AVCapturePhotoOutput()
        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            throw PigeonError(code: "output_failed", message: "cannot add the photo output", details: nil)
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        // R2 §8: content-aware correction is applied at the output's own
        // discretion, so a fixed intrinsics model and this feature are mutually
        // exclusive. Off, at the output level, before anything is captured.
        if #available(iOS 14.1, *), photoOutput.isContentAwareDistortionCorrectionSupported {
            photoOutput.isContentAwareDistortionCorrectionEnabled = false
        }
        // iOS 17 will otherwise hand back an AVCaptureDeferredPhotoProxy instead
        // of a photo, which has no pixels to fuse and no EXIF to check the
        // achieved exposure against.
        if #available(iOS 17.0, *), photoOutput.isAutoDeferredPhotoDeliverySupported {
            photoOutput.isAutoDeferredPhotoDeliveryEnabled = false
        }
        if photoOutput.isCameraCalibrationDataDeliverySupported {
            photoOutput.isVirtualDeviceConstituentPhotoDeliveryEnabled =
                photoOutput.isVirtualDeviceConstituentPhotoDeliverySupported
        }
        self.photoOutput = photoOutput

        // The video output does double duty: it is the preview (§4) and it is
        // the only place tier 2 of the intrinsics chain can be observed —
        // `cameraIntrinsicMatrix` arrives as a sample-buffer attachment on
        // AVCaptureVideoDataOutput and is not available from photo output at
        // all (Math §4.2).
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        let previewWidth = max(160, Int(request.previewTargetWidth))
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw PigeonError(code: "output_failed", message: "cannot add the video output", details: nil)
        }
        session.addOutput(videoOutput)
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        self.videoOutput = videoOutput

        session.commitConfiguration()

        // Format selection comes after commit so `activeFormat` reflects the
        // preset's own choice before we second-guess it.
        try configureFormat(device: device, request: request, warnings: &warnings)

        if let connection = videoOutput.connection(with: .video) {
            // Stabilisation warps the frame, which is precisely what a fixed
            // intrinsics model may not tolerate — and it is also the variable
            // the conflicting 2017–18 reports blame for breaking intrinsic
            // matrix delivery (R2 §6). Off on both counts.
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
            if connection.isCameraIntrinsicMatrixDeliverySupported {
                connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
        }

        // Scale the preview to ~1280 wide — but **never above what the active
        // format's video stream can produce**. The capture path is untouched: this
        // only sizes the buffers the viewfinder draws.
        //
        // This raised `NSInvalidArgumentException` on an iPhone 17 Pro:
        //
        //   -[AVCaptureVideoDataOutput setVideoSettings:] Video settings dimensions
        //   must not be larger than the source device activeFormat's dimensions
        //
        // and an Objective-C exception is a `SIGABRT`, not something Swift can catch.
        // The cause is upstream: `configureFormat` ranks formats by their **photo**
        // dimensions (`largestPhotoSize` reads `supportedMaxPhotoDimensions`) and
        // never looks at their video dimensions. Since iOS 16 a format's photo
        // pipeline can far exceed its video stream, so "largest 4:3 photo" can win
        // with a format whose video is smaller than the preview being asked for.
        //
        // The aspect comes from the **video** description too. Deriving it from the
        // photo aspect described a rectangle the video stream does not produce, so
        // even when the numbers happened to fit, the shape was a guess.
        let videoDimensions = CMVideoFormatDescriptionGetDimensions(
            device.activeFormat.formatDescription)
        let cappedWidth = max(160, min(previewWidth, Int(videoDimensions.width)))
        let videoAspect =
            videoDimensions.height > 0
            ? Double(videoDimensions.width) / Double(videoDimensions.height)
            : 4.0 / 3.0
        let cappedHeight = max(
            120,
            min(
                Int((Double(cappedWidth) / videoAspect).rounded()),
                Int(videoDimensions.height)))
        previewSize = PlatformSize(width: Int64(cappedWidth), height: Int64(cappedHeight))

        // Apple's contract: this must be `false` before `videoSettings` carries
        // explicit dimensions, or the output goes on owning the buffer size and the
        // request is advisory at best.
        videoOutput.automaticallyConfiguresOutputBufferDimensions = false
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: cappedWidth,
            kCVPixelBufferHeightKey as String: cappedHeight,
        ]
        if cappedWidth < previewWidth {
            // Worth saying rather than swallowing: the format that shoots the biggest
            // still on this device has a small video stream, so the viewfinder is
            // softer than asked for. The stills — which is what the panorama is made
            // of — are unaffected.
            warnings.append(
                "the active format's video stream is \(videoDimensions.width)×"
                    + "\(videoDimensions.height), so the preview was capped at \(cappedWidth)×"
                    + "\(cappedHeight) rather than the \(previewWidth) px requested; this affects "
                    + "the viewfinder only, not the captured frames")
        }

        let texture = PreviewTexture()
        previewTexture = texture
        // On the platform thread, like everything else that touches the
        // registry. `textureFrameAvailable` below is the documented exception —
        // Flutter's own camera plugin calls it from the sample-buffer queue —
        // but registration and unregistration are not, and the Android half of
        // this plugin had exactly this bug: `createSurfaceTexture()` off the
        // platform thread threw `Can't create handler inside thread ... that has
        // not called Looper.prepare()` and surfaced as `open_failed`. iOS races
        // instead of throwing, which is worse to diagnose, not better.
        textureId = onPlatformThread { self.textures.register(texture) }

        registerInterruptionObservers(session: session)
        self.session = session
        session.startRunning()

        mapper = TimestampMapper()

        // Disable both distortion corrections on the device before anything is
        // measured, so the field of view read below describes the frames that
        // will actually be delivered.
        let gdcDisabled = disableGeometricDistortionCorrection(device: device)
        if !gdcDisabled && device.isGeometricDistortionCorrectionSupported {
            warnings.append(
                "geometric distortion correction could not be disabled; videoFieldOfView describes "
                    + "the post-correction frame and the fixed intrinsics model below does not "
                    + "describe the delivered pixels")
        }

        // Give the video output long enough to prove — or fail to prove — that
        // the tier-2 attachment arrives. Reporting the capability flag instead
        // is the mistake that left this question open since 2017.
        Thread.sleep(forTimeInterval: CameraSessionIOS.intrinsicProbeSeconds)

        let calibration = probeCalibrationData(photoOutput: photoOutput, warnings: &warnings)

        maxBracketCount = photoOutput.maxBracketedCapturePhotoCount
        bracketMode = resolveBracketMode(device: device, warnings: &warnings)

        let facts = buildFacts(
            device: device,
            photoOutput: photoOutput,
            calibration: calibration,
            gdcDisabled: gdcDisabled)

        return CameraOpenResult(
            captureSize: captureSize,
            previewSize: previewSize,
            // iOS delivers photos already in the sensor's landscape orientation
            // for a back camera, with rotation carried in EXIF rather than
            // applied. There is no sensor mounting angle to reconcile.
            sensorOrientationDegrees: 0,
            // 90, and reported rather than achieved.
            //
            // The obvious move is to set `videoRotationAngle` (or the older
            // `videoOrientation`) on the video output's connection so the buffer
            // arrives upright, and it is the wrong one. That same connection
            // delivers the **camera intrinsic matrix** — see
            // `isCameraIntrinsicMatrixDeliveryEnabled` above — which is tier 2 of
            // the intrinsics chain in `intrinsics_resolver.dart` and the only route
            // to real calibration on this platform. Stabilisation is already turned
            // off there *because* R2 §6 found it blamed for breaking that delivery;
            // rotating the same connection is the same gamble, and it would leave
            // `connectionIntrinsicReferenceSize` describing a frame the resolver
            // does not expect.
            //
            // So the buffer stays as the sensor read it — landscape, straight
            // through `PreviewTexture` untouched — and Dart turns it, on exactly
            // the code path Android uses when Android reports the same thing.
            // Neither platform gets a special case; both state a number.
            previewRotationDegrees: 90,
            // Nothing in the iOS render path applies the metadata: the pixel
            // buffer goes from `captureOutput` to `PreviewTexture` to Flutter with
            // no transform anywhere.
            previewHandlesRotation: false,
            clock: mapper!.toInfo(),
            bracketMode: bracketMode,
            maxBracketCount: Int64(max(maxBracketCount, 1)),
            captureAspectIsFourThree: isFourThree(captureSize),
            androidFacts: nil,
            iosFacts: facts,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: "; ")
        )
    }

    /// §2.1's 4:3 preference, applied on iOS.
    ///
    /// The `.photo` preset already picks a 4:3 still format on every current
    /// iPad, so this usually confirms rather than changes anything. It is still
    /// worth doing: a 4:3 stream off a 4:3 sensor is a pure scale, so no crop
    /// term enters the intrinsics, and it is the largest vertical field of view
    /// the camera can give — which directly reduces the number of rings.
    /// Writes a photo with its EXIF `Orientation` forced to 1, keeping the pixels
    /// exactly as AVFoundation delivered them.
    ///
    /// **The iOS half of the pipeline's orientation contract.** AVFoundation hands
    /// back landscape pixel rows and stamps the rotation into metadata from the
    /// photo connection — a connection nothing here configures — so
    /// `fileDataRepresentation()` embeds a non-normal tag over landscape pixels.
    /// Everything downstream describes the frame *as the sensor delivered it*: the
    /// intrinsics, `captureQuarterTurns`, the undistort maps, the warp's principal
    /// point. A consumer that applies the tag therefore sees a transposed frame
    /// against untransposed intrinsics.
    ///
    /// The stitcher is already defended — `sv_geometry.cpp` decodes with
    /// `IMREAD_IGNORE_ORIENTATION` — but the bundle is meant to be copied off the
    /// device and read by other things: a host app, a gallery, `cv::imread` without
    /// the flag, the `image` package. Normalising here is what makes "the pixels on
    /// disk are the capture frame" true of the file rather than true only of the
    /// one reader that knows to ignore the tag.
    ///
    /// The tag is rewritten; the pixels are **not** re-encoded and **not** rotated.
    /// Re-encoding would cost quality on every frame of every capture to fix
    /// metadata, and rotating would break the three things above that depend on
    /// landscape-as-delivered.
    ///
    /// Best effort, and never throws: a photo with an awkward tag is worth more
    /// than no photo, and the native decode-size check fails loudly if this does
    /// not hold. The Android twin is `ImageUtils.normaliseExifOrientation`.
    private static func writeWithNormalOrientation(_ data: Data, to url: URL) {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(source),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)
        else {
            try? data.write(to: url)
            return
        }
        var properties =
            (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        properties[kCGImagePropertyOrientation] = CGImagePropertyOrientation.up.rawValue
        // `AddImageFromSource` copies the encoded image data through rather than
        // decoding and re-encoding it, so this is a metadata rewrite and the JPEG
        // is bit-identical apart from the tag.
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        if !CGImageDestinationFinalize(destination) {
            try? data.write(to: url)
        }
    }

    private func configureFormat(
        device: AVCaptureDevice,
        request: CaptureFormatRequest,
        warnings: inout [String]
    ) throws {
        var chosen = largestPhotoSize(for: device.activeFormat)

        if let requested = request.captureSize {
            if let format = device.formats.first(where: {
                photoSizes(forFormat: $0).contains {
                    Int64($0.width) == requested.width && Int64($0.height) == requested.height
                }
            }) {
                try setActiveFormat(device: device, format: format)
                chosen = CMVideoDimensions(
                    width: Int32(requested.width), height: Int32(requested.height))
            } else {
                warnings.append(
                    "requested capture size \(requested.width)x\(requested.height) is not offered "
                        + "by any format; kept the preset's own choice")
            }
        } else if request.preferFourThree
            && !isFourThree(PlatformSize(width: Int64(chosen.width), height: Int64(chosen.height)))
        {
            let fourThree = device.formats
                .compactMap { format -> (AVCaptureDevice.Format, CMVideoDimensions)? in
                    let size = largestPhotoSize(for: format)
                    let long = Double(max(size.width, size.height))
                    let short = Double(min(size.width, size.height))
                    guard short > 0, abs(long / short - 4.0 / 3.0) < 0.02 else { return nil }
                    return (format, size)
                }
                .max { Int($0.1.width) * Int($0.1.height) < Int($1.1.width) * Int($1.1.height) }

            if let (format, size) = fourThree {
                try setActiveFormat(device: device, format: format)
                chosen = size
            } else {
                warnings.append(
                    "no 4:3 photo format is available; the intrinsics derivation picks up a crop "
                        + "term and the vertical field of view is smaller than this camera can give")
            }
        }

        // maxPhotoDimensions must be raised explicitly on iOS 16+, or the
        // output silently caps the still at the video dimensions.
        if #available(iOS 16.0, *), let output = photoOutput {
            let supported = device.activeFormat.supportedMaxPhotoDimensions
            if let largest = supported.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
                output.maxPhotoDimensions = largest
                chosen = largest
            }
        }

        captureSize = PlatformSize(width: Int64(chosen.width), height: Int64(chosen.height))
    }

    private func setActiveFormat(device: AVCaptureDevice, format: AVCaptureDevice.Format) throws {
        try device.lockForConfiguration()
        device.activeFormat = format
        device.unlockForConfiguration()
    }

    /// Applies a custom exposure, with the duration and ISO forced inside the
    /// active format's range first.
    ///
    /// **The only way this class is allowed to call `setExposureModeCustom`.**
    /// AVFoundation raises `NSRangeException` for a duration or an ISO outside
    /// `activeFormat`'s advertised range, and an Objective-C exception is not
    /// catchable from Swift — it is a `SIGABRT`, not an error. So the range has to
    /// be enforced here rather than hoped for at each call site, and the call
    /// sites had drifted: one clamped the ISO but not the duration, one clamped
    /// neither, and one passed `CMTime.zero` outright.
    ///
    /// A non-finite or non-positive duration is not clamped, it is **refused** —
    /// `NaN` propagates through Swift's `min`/`max` untouched, so clamping it
    /// would hand AVFoundation the same illegal value with a clear conscience.
    /// Returns whether the exposure was applied, so a caller can say so.
    @discardableResult
    private func applyCustomExposure(
        device: AVCaptureDevice,
        duration: CMTime,
        iso: Float,
        timeout: Double = 2.0
    ) -> Bool {
        guard device.isExposureModeSupported(.custom) else { return false }
        guard
            let (clampedDuration, clampedISO) = Self.clampedExposure(
                format: device.activeFormat, duration: duration, iso: iso)
        else { return false }

        guard (try? device.lockForConfiguration()) != nil else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        device.setExposureModeCustom(duration: clampedDuration, iso: clampedISO) { _ in
            semaphore.signal()
        }
        device.unlockForConfiguration()
        _ = semaphore.wait(timeout: .now() + timeout)
        return true
    }

    /// The largest photo size the **active format** will actually accept on a
    /// settings object, or `nil` when the ceiling cannot be trusted.
    ///
    /// `settings.maxPhotoDimensions` must be a member of the active format's
    /// `supportedMaxPhotoDimensions`; anything else raises `NSInvalidArgumentException`
    /// from `capturePhoto`. The two fire paths were assigning the *output's* ceiling,
    /// which is consistent today only because `configureFormat` happens to source it
    /// from the same format — nothing enforces that, and a format change would make it
    /// silently illegal.
    @available(iOS 16.0, *)
    private func settingsPhotoCeiling(_ output: AVCapturePhotoOutput) -> CMVideoDimensions? {
        guard let format = device?.activeFormat else { return nil }
        let supported = format.supportedMaxPhotoDimensions
        let ceiling = output.maxPhotoDimensions
        if supported.contains(where: { $0.width == ceiling.width && $0.height == ceiling.height }) {
            return ceiling
        }
        // Not a member: fall back to the largest the format does admit rather than
        // pass a value that would abort the process.
        return supported.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) })
    }

    /// The exposure range rule, with no side effects and no lock.
    ///
    /// Split out because `applyLock` has to clamp while already *holding* the
    /// configuration lock, and taking it twice is its own bug. One definition of
    /// what AVFoundation will accept; two callers with different locking.
    ///
    /// `nil` means refuse rather than clamp. A `NaN` passes through Swift's
    /// `min`/`max` unchanged, so clamping a non-finite value would hand
    /// AVFoundation exactly the illegal number it raises on.
    private static func clampedExposure(
        format: AVCaptureDevice.Format,
        duration: CMTime,
        iso: Float
    ) -> (CMTime, Float)? {
        let seconds = CMTimeGetSeconds(duration)
        guard duration.isValid, seconds.isFinite, seconds > 0, iso.isFinite else { return nil }

        let minSeconds = CMTimeGetSeconds(format.minExposureDuration)
        let maxSeconds = CMTimeGetSeconds(format.maxExposureDuration)
        guard minSeconds.isFinite, maxSeconds.isFinite, minSeconds > 0 else { return nil }

        // Rebuilt at the format's own timescale rather than a nanosecond one: the
        // round trip through `CMTimeMakeWithSeconds` is what can leave a duration a
        // tick below `minExposureDuration` after it was clamped to exactly that.
        let clampedSeconds = min(max(seconds, minSeconds), maxSeconds)
        return (
            CMTimeMakeWithSeconds(
                clampedSeconds, preferredTimescale: format.minExposureDuration.timescale),
            min(max(iso, format.minISO), format.maxISO)
        )
    }

    /// Tier 1, attempted only where the platform says it is possible.
    ///
    /// R2 §6, on an Apple engineer's word: calibration delivery needs a
    /// multi-camera *virtual device* plus GDC off plus content-aware correction
    /// off, and there is no degraded single-lens mode — it is simply
    /// unavailable there. Spike B's expectation is that no current iPad
    /// qualifies at all, the last one being the 2022 M2 iPad Pro. So the cost
    /// of the throwaway probe photo below is only ever paid by a device that
    /// can actually answer.
    private func probeCalibrationData(
        photoOutput: AVCapturePhotoOutput,
        warnings: inout [String]
    ) -> AVCameraCalibrationData? {
        guard photoOutput.isCameraCalibrationDataDeliverySupported else { return nil }

        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        // Calibration delivery is only legal alongside constituent-photo delivery from
        // **two or more** physical cameras. The output-level flag was set in `open()`;
        // the settings need the device list as well, and AVFoundation raises
        // `NSInvalidArgumentException` from `capturePhoto` when it is missing — on
        // precisely the multi-camera devices this probe exists to interrogate, and
        // during `open()`, so the session dies before the user sees a viewfinder.
        //
        // Below two constituents there is no degraded mode to fall back to (R2 §6),
        // so the probe is skipped rather than attempted: it could only ever raise.
        let constituents = (device?.constituentDevices ?? []).filter { _ in true }
        guard photoOutput.isVirtualDeviceConstituentPhotoDeliverySupported,
              constituents.count >= 2
        else {
            warnings.append(
                "camera calibration delivery is advertised but this camera exposes "
                    + "\(constituents.count) constituent lens(es); it needs at least two, so the "
                    + "probe was skipped and the intrinsics fall to the next rung")
            return nil
        }
        settings.virtualDeviceConstituentPhotoDeliveryEnabledDevices = constituents
        settings.isCameraCalibrationDataDeliveryEnabled = true
        if #available(iOS 14.1, *) {
            settings.isAutoContentAwareDistortionCorrectionEnabled = false
        }

        let semaphore = DispatchSemaphore(value: 0)
        let delegate = PhotoCaptureDelegate(expected: 1) { _, _ in
            semaphore.signal()
        }
        retainedDelegates.append(delegate)
        photoOutput.capturePhoto(with: settings, delegate: delegate)
        if semaphore.wait(timeout: .now() + 5.0) == .timedOut {
            warnings.append("the calibration-data probe capture timed out")
        }
        retainedDelegates.removeAll { $0 === delegate }
        return delegate.photosSoFar().first?.cameraCalibrationData
    }

    private func buildFacts(
        device: AVCaptureDevice,
        photoOutput: AVCapturePhotoOutput,
        calibration: AVCameraCalibrationData?,
        gdcDisabled: Bool
    ) -> IosIntrinsicFacts {
        intrinsicsLock.lock()
        let matrix = observedIntrinsicMatrix
        let reference = observedIntrinsicReference
        let arrived = intrinsicAttachmentArrived
        intrinsicsLock.unlock()

        let connectionSupported =
            videoOutput?.connection(with: .video)?.isCameraIntrinsicMatrixDeliverySupported ?? false

        var calibrationMatrix: [Double]?
        var calibrationReference: PlatformSize?
        var lookupTable: [Double]?
        var centerX: Double?
        var centerY: Double?
        if let calibration = calibration {
            calibrationMatrix = rowMajor(calibration.intrinsicMatrix)
            calibrationReference = PlatformSize(
                width: Int64(calibration.intrinsicMatrixReferenceDimensions.width),
                height: Int64(calibration.intrinsicMatrixReferenceDimensions.height))
            lookupTable = calibration.lensDistortionLookupTable.map { data in
                data.withUnsafeBytes { raw in
                    raw.bindMemory(to: Float.self).map { Double($0) }
                }
            }
            centerX = Double(calibration.lensDistortionCenter.x)
            centerY = Double(calibration.lensDistortionCenter.y)
        }

        var contentAwareDisabled = true
        if #available(iOS 14.1, *), photoOutput.isContentAwareDistortionCorrectionSupported {
            contentAwareDisabled = !photoOutput.isContentAwareDistortionCorrectionEnabled
        }

        return IosIntrinsicFacts(
            calibrationIntrinsicMatrix: calibrationMatrix,
            calibrationReferenceSize: calibrationReference,
            connectionIntrinsicMatrix: matrix,
            connectionIntrinsicReferenceSize: reference,
            connectionIntrinsicDeliverySupported: connectionSupported,
            connectionIntrinsicAttachmentArrived: arrived,
            // R2 confirmed this is HORIZONTAL, not diagonal, and it is read
            // here rather than `geometricDistortionCorrectedVideoFieldOfView`,
            // which describes the post-GDC frame and only applies while GDC is
            // on — which it is not.
            videoFieldOfViewDegrees: Double(device.activeFormat.videoFieldOfView),
            lensDistortionLookupTable: lookupTable,
            lensDistortionCenterX: centerX,
            lensDistortionCenterY: centerY,
            geometricDistortionCorrectionDisabled: gdcDisabled,
            contentAwareDistortionCorrectionDisabled: contentAwareDisabled,
            calibrationDataDeliverySupported: photoOutput.isCameraCalibrationDataDeliverySupported,
            isVirtualDevice: device.isVirtualDevice,
            focalLengthIn35mmFilm: nil
        )
    }

    private func resolveBracketMode(device: AVCaptureDevice, warnings: inout [String])
        -> PlatformBracketMode
    {
        guard device.isExposureModeSupported(.custom) else {
            warnings.append(
                "this device does not support custom exposure, so the bracket collapses to a "
                    + "single frame — not a degradation of quality but of dynamic range, and it "
                    + "must not be read as a bracket")
            return .singleShot
        }
        if maxBracketCount >= 2 { return .photoBracket }
        warnings.append(
            "maxBracketedCapturePhotoCount is \(maxBracketCount) at this preset and format, so "
                + "bracketed capture is unavailable; falling back to sequential single shots with "
                + "the exposure changed between them, which puts the frames further apart in time")
        return .sequentialManual
    }

    // MARK: - preview

    func attachPreview() throws -> Int64 {
        guard let id = textureId else {
            throw PigeonError(code: "not_open", message: "the camera is not open", details: nil)
        }
        return id
    }

    func detachPreview() {
        previewTexture?.clear()
    }

    // MARK: - meter and lock

    func meterAndLock(durationSeconds: Double) throws -> MeteringResult {
        guard let device = device else {
            throw PigeonError(code: "not_open", message: "the camera is not open", details: nil)
        }
        var notes: [String] = []

        // §2.3 steps 1–2: full auto while the user pans the sphere, recording
        // what auto-exposure settles on. Locking on the first frame instead
        // would meter whichever wall the user happens to be facing.
        // `try?` and then mutate anyway is not safe here: setting these without a
        // held lock raises an Objective-C exception, which Swift cannot catch, so a
        // device momentarily held by another client would take the whole app down
        // rather than degrade. `applyLock` already does this correctly; this site
        // and the unlocked branch of `captureBracket` did not.
        if (try? device.lockForConfiguration()) != nil {
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.isSubjectAreaChangeMonitoringEnabled = false
            device.unlockForConfiguration()
        }

        let sweep = max(0.2, min(durationSeconds, 20.0))
        let interval = 1.0 / 30.0
        var products: [Double] = []
        var sampleCount = 0
        let deadline = Date().addingTimeInterval(sweep)
        while Date() < deadline {
            let duration = CMTimeGetSeconds(device.exposureDuration)
            let iso = Double(device.iso)
            if duration > 0 && iso > 0 {
                products.append(duration * iso)
                sampleCount += 1
            }
            Thread.sleep(forTimeInterval: interval)
        }

        let aeConverged = !device.isAdjustingExposure

        var chosenDuration = device.exposureDuration
        var chosenISO = device.iso
        var meanEv = 0.0
        var percentileEv = 0.0

        if products.isEmpty {
            notes.append(
                "the metering sweep produced no usable exposure readings, so the lock is whatever "
                    + "the device last reported")
        } else {
            let sorted = products.sorted()
            let median = sorted[sorted.count / 2]
            // Scene brightness in stops relative to the sweep's median frame.
            // The exposure product moves *against* brightness — a bright window
            // needs less light collected — hence the negation. Getting this
            // sign wrong would meter every interior for the darkest corner it
            // saw.
            let evs = products.map { -log2($0 / median) }.sorted()
            meanEv = evs.reduce(0, +) / Double(evs.count)
            let index = Int((Double(evs.count - 1) * CameraSessionIOS.exposurePercentile).rounded())
            percentileEv = evs[max(0, min(index, evs.count - 1))]

            if meanEv - percentileEv > 0.5 {
                notes.append(
                    String(
                        format:
                            "the sweep's exposure distribution is skewed by %.2f EV — bright windows "
                            + "are pulling the mean above the %.0fth percentile, which is exactly "
                            + "the case §2.3 says not to meter for",
                        meanEv - percentileEv, CameraSessionIOS.exposurePercentile * 100))
            }

            let targetProduct = median * pow(2.0, -percentileEv)
            let format = device.activeFormat
            chosenISO = min(max(device.iso, format.minISO), format.maxISO)
            var seconds = targetProduct / Double(chosenISO)
            let minSeconds = CMTimeGetSeconds(format.minExposureDuration)
            let maxSeconds = CMTimeGetSeconds(format.maxExposureDuration)
            if seconds < minSeconds || seconds > maxSeconds {
                let bounded = min(max(seconds, minSeconds), maxSeconds)
                let residual = seconds / bounded
                seconds = bounded
                chosenISO = min(max(Float(Double(chosenISO) * residual), format.minISO), format.maxISO)
                notes.append(
                    "the chosen exposure fell outside the format's range and the residual moved to "
                        + "ISO \(Int(chosenISO))")
            }
            chosenDuration = CMTimeMakeWithSeconds(seconds, preferredTimescale: 1_000_000_000)
        }

        lockQuality = try applyLock(
            device: device, duration: chosenDuration, iso: chosenISO, notes: &notes)
        baseDuration = device.exposureDuration
        baseISO = device.iso
        isLocked = lockQuality != .unlocked

        let temperature = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)

        return MeteringResult(
            exposureTimeNs: Int64((CMTimeGetSeconds(baseDuration) * 1e9).rounded()),
            iso: Int64(baseISO.rounded()),
            colorTemperatureK: Int64(temperature.temperature.rounded()),
            // AVFoundation exposes lens position as a unitless 0–1 value, not a
            // distance, so there is nothing to convert to dioptres and nothing
            // to clamp against the 1.5–3 m window the Android path uses. The
            // lens position that was locked is recorded in the note instead of
            // being dressed up as a measurement.
            focusDistanceDiopters: 0,
            lockQuality: lockQuality,
            sampleCount: Int64(sampleCount),
            chosenEv: percentileEv,
            meanEv: meanEv,
            percentile65Ev: percentileEv,
            aeConverged: aeConverged,
            // iOS exposes no per-frame ISP mode controls at all — no equivalent
            // of NOISE_REDUCTION_MODE, EDGE_MODE or TONEMAP_MODE. What it does
            // expose, and what §3.3 says is essential, is the device's own HDR,
            // which is the iOS analogue of an adaptive tonemap: leaving it on
            // means per-frame tone mapping that both fights the bracket and
            // breaks photometric consistency. That is switched off in
            // applyLock, and it is what this flag reports.
            pinnedProcessingModes: !device.isVideoHDREnabled,
            note:
                (notes + [
                    "iOS locked at lens position \(device.lensPosition) (unitless); "
                        + "videoHDREnabled=\(device.isVideoHDREnabled)"
                ]).joined(separator: "; ")
        )
    }

    /// §3.3, in the order the properties have to be set.
    ///
    /// `automaticallyAdjustsVideoHDREnabled` must go false *before*
    /// `videoHDREnabled` — while the automatic flag is on, the manual one is
    /// read-only and assigning to it raises. Disabling the device's own HDR is
    /// not optional: leaving it on means the ISP applies its own per-frame tone
    /// mapping, which both fights our bracket and destroys the photometric
    /// consistency between panorama positions that the whole locked-exposure
    /// design exists to produce.
    private func applyLock(
        device: AVCaptureDevice,
        duration: CMTime,
        iso: Float,
        notes: inout [String]
    ) throws -> PlatformLockQuality {
        do {
            try device.lockForConfiguration()
        } catch {
            notes.append("lockForConfiguration failed: \(error)")
            return .unlocked
        }

        if device.activeFormat.isVideoHDRSupported {
            device.automaticallyAdjustsVideoHDREnabled = false
            device.isVideoHDREnabled = false
        }
        _ = disableGeometricDistortionCorrectionLocked(device: device)
        device.isSubjectAreaChangeMonitoringEnabled = false

        // R3 finding 1: neither bracket type locks focus or white balance, so
        // both are locked here, explicitly, before any bracket is built.
        var focusLocked = false
        if device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
            focusLocked = true
        } else {
            notes.append("this device does not support a locked focus mode")
        }

        var whiteBalanceLocked = false
        if device.isWhiteBalanceModeSupported(.locked) {
            device.whiteBalanceMode = .locked
            whiteBalanceLocked = true
        } else {
            notes.append("this device does not support a locked white balance mode")
        }

        var exposureLocked = false
        // The ISO was clamped here and the duration was not, which is the same class
        // of bug as the crash in `fireSequential` and was one rounding error away
        // from the same `NSRangeException`. Both go through one rule now. The lock is
        // already held on this path, so this uses the pure clamp rather than
        // `applyCustomExposure`, which takes its own.
        if device.isExposureModeSupported(.custom),
           let (lockDuration, lockISO) = Self.clampedExposure(
               format: device.activeFormat, duration: duration, iso: iso) {
            let semaphore = DispatchSemaphore(value: 0)
            device.setExposureModeCustom(duration: lockDuration, iso: lockISO) { _ in
                semaphore.signal()
            }
            device.unlockForConfiguration()
            // §7 pitfall 6: the lock is not in effect until the completion
            // handler fires. Skipping the wait leaves the first frames of the
            // session inconsistent with the rest — and those are the frames the
            // user is most likely to be pointing at something bright.
            if semaphore.wait(timeout: .now() + 3.0) == .timedOut {
                notes.append(
                    "setExposureModeCustom did not call back within 3 s; the lock may not be in "
                        + "effect for the first frames")
            }
            exposureLocked = true
        } else {
            device.exposureMode = device.isExposureModeSupported(.locked) ? .locked : device.exposureMode
            device.unlockForConfiguration()
            notes.append(
                "custom exposure is unsupported; exposure is held with .locked, which the platform "
                    + "may still re-converge from")
        }

        if exposureLocked && whiteBalanceLocked && focusLocked { return .fullyLocked }
        if exposureLocked || whiteBalanceLocked { return .bestEffort }
        return .unlocked
    }

    func unlock() {
        guard let device = device, (try? device.lockForConfiguration()) != nil else { return }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        device.unlockForConfiguration()
        isLocked = false
        lockQuality = .unlocked
    }

    @discardableResult
    private func disableGeometricDistortionCorrection(device: AVCaptureDevice) -> Bool {
        guard (try? device.lockForConfiguration()) != nil else { return false }
        defer { device.unlockForConfiguration() }
        return disableGeometricDistortionCorrectionLocked(device: device)
    }

    @discardableResult
    private func disableGeometricDistortionCorrectionLocked(device: AVCaptureDevice) -> Bool {
        guard device.isGeometricDistortionCorrectionSupported else {
            // Nothing to disable means nothing is being applied, which is the
            // state the fixed intrinsics model needs.
            return true
        }
        device.isGeometricDistortionCorrectionEnabled = false
        return !device.isGeometricDistortionCorrectionEnabled
    }

    // MARK: - bracket

    private var retainedDelegates: [PhotoCaptureDelegate] = []

    func captureBracket(
        evBiases: [Double],
        outputDirectory: String,
        namePrefix: String
    ) throws -> CaptureResponse {
        guard let device = device, let photoOutput = photoOutput, let mapper = mapper else {
            throw PigeonError(code: "not_open", message: "the camera is not open", details: nil)
        }
        var notes: [String] = []

        try? FileManager.default.createDirectory(
            atPath: outputDirectory, withIntermediateDirectories: true)

        // R3 finding 2: query, do not assume. The count varies with preset and
        // active format, and Apple publishes no per-device table.
        let available = photoOutput.maxBracketedCapturePhotoCount
        var biases = evBiases.isEmpty ? [0.0] : evBiases

        // `ExposureStrategy.auto`: nothing was ever locked, so leave the device on
        // the `.continuousAutoExposure` it has been in since `open` and take one
        // frame. Forced ahead of every branch below because `planBracket` would
        // otherwise build a *custom*-exposure bracket from a base exposure it has
        // no lock to read, and the Android twin of this path fell back to a
        // hard-coded 1/60 s at ISO 100 — several stops under indoors.
        let unlocked = lockQuality == .unlocked
        if unlocked {
            biases = [0.0]
            if device.isExposureModeSupported(.continuousAutoExposure),
               (try? device.lockForConfiguration()) != nil {
                device.exposureMode = .continuousAutoExposure
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                device.unlockForConfiguration()
            }
        }

        if unlocked {
            // one auto-metered frame; no bracket of any kind
        } else if bracketMode == .singleShot {
            if biases.count > 1 {
                notes.append(
                    "this device has no custom exposure control, so the \(biases.count)-shot "
                        + "bracket collapsed to a single frame at the metered lock")
            }
            biases = [0.0]
        } else if biases.count > available && available >= 2 {
            // Trim to the widest pair rather than the first N: a bracket's
            // value is its spread, so keeping −2 and +2 preserves the dynamic
            // range where keeping −2 and 0 halves it. R3 names the 2-shot
            // bracket as the intermediate fallback before abandoning HDR.
            let trimmed = [biases.first!, biases.last!]
            notes.append(
                "maxBracketedCapturePhotoCount is \(available) but \(biases.count) exposures were "
                    + "requested; trimmed to the widest pair \(trimmed)")
            biases = trimmed
        }

        let plan = planBracket(device: device, biases: biases, notes: &notes)

        let start = TimestampMapper.hostTimeSeconds()
        var photos: [AVCapturePhoto] = []
        var shutterTimes: [Double] = []

        if !unlocked && bracketMode == .photoBracket && plan.count > 1 {
            photos = try fireBracket(
                photoOutput: photoOutput, plan: plan, shutterTimes: &shutterTimes, notes: &notes)
        } else {
            photos = try fireSequential(
                device: device, photoOutput: photoOutput, plan: plan,
                shutterTimes: &shutterTimes, notes: &notes)
        }

        // Timing stops at pixel delivery, not at capture completion: metadata
        // routinely completes well before pixels are in hand, and pixels are
        // what Phase 05 needs. Timing the metadata would give a flattering,
        // useless number (Spike C).
        let wallClockMs = (TimestampMapper.hostTimeSeconds() - start) * 1000

        let baseProduct = CMTimeGetSeconds(baseDuration) * Double(baseISO)
        var frames: [PlatformFrame] = []
        for (index, photo) in photos.enumerated() {
            guard let data = photo.fileDataRepresentation() else {
                notes.append("frame \(index) produced no file data")
                continue
            }
            let bias = index < plan.count ? plan[index].evBias : 0
            let url = URL(fileURLWithPath: outputDirectory)
                .appendingPathComponent(String(format: "%@_%d_ev%+.2f.jpg", namePrefix, index, bias))
            Self.writeWithNormalOrientation(data, to: url)

            // EXIF is the ground truth for what the sensor actually did, as
            // opposed to what was asked for — and it is where the drift that
            // Forums #749574 reports on iPad 8 and iPhone 15 would become
            // visible rather than mysterious.
            var exposureSeconds: Double?
            var exifISO: Double?
            if let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                exposureSeconds = exif[kCGImagePropertyExifExposureTime as String] as? Double
                exifISO = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?
                    .first?.doubleValue
            }
            let means = computeStatistics ? ImageStatistics.centreMeansRgb(jpeg: data) : nil

            frames.append(
                PlatformFrame(
                    filePath: url.path,
                    evBias: bias,
                    timestampUs: mapper.toMotionClockUs(photo.timestamp),
                    byteCount: Int64(data.count),
                    exposureTimeNs: exposureSeconds.map { Int64(($0 * 1e9).rounded()) },
                    iso: exifISO.map { Int64($0.rounded()) },
                    achievedEvBias: {
                        guard let e = exposureSeconds, let i = exifISO, baseProduct > 0 else {
                            return nil
                        }
                        return log2((e * i) / baseProduct)
                    }(),
                    meanR: means?[0],
                    meanG: means?[1],
                    meanB: means?[2],
                    note: index < plan.count ? plan[index].note : nil
                ))
        }

        return CaptureResponse(
            frames: frames,
            burstWallClockMs: wallClockMs,
            shutterToShutterMs: zip(shutterTimes, shutterTimes.dropFirst()).map { ($1 - $0) * 1000 },
            mode: bracketMode,
            clampedExposure: plan.contains { $0.clampedDuration },
            clampedIso: plan.contains { $0.clampedISO },
            // Nothing is deferred on iOS: the photo output hands back encoded
            // JPEGs, so there is no encode to move off the hot path.
            deferredEncodeMs: 0,
            note: notes.isEmpty ? nil : notes.joined(separator: "; ")
        )
    }

    private struct PlannedShot {
        let evBias: Double
        let duration: CMTime
        let iso: Float
        let clampedDuration: Bool
        let clampedISO: Bool
        let note: String?
    }

    /// §2.4's rule, applied on iOS: **vary exposure time, not ISO.**
    ///
    /// Changing ISO between bracket frames changes the noise between them,
    /// which confuses both the Mertens fusion weighting and the ghost detector
    /// — Phase 05 compares the frames against each other, and a difference in
    /// grain reads as a difference in content. ISO is only touched when the
    /// shutter hits a wall, and every such case is reported.
    private func planBracket(
        device: AVCaptureDevice, biases: [Double], notes: inout [String]
    ) -> [PlannedShot] {
        let format = device.activeFormat
        let base = baseDuration.isValid && baseDuration.seconds > 0
            ? baseDuration : device.exposureDuration
        let baseSeconds = CMTimeGetSeconds(base)
        let iso = baseISO > 0 ? baseISO : device.iso

        let minSeconds = CMTimeGetSeconds(format.minExposureDuration)
        let ceilingSeconds = min(
            max(CameraSessionIOS.motionBlurLimitSeconds, baseSeconds),
            CMTimeGetSeconds(format.maxExposureDuration))

        return biases.map { ev in
            var seconds = baseSeconds * pow(2.0, ev)
            var shotISO = iso
            var clampedDuration = false
            var clampedISO = false
            var note: String?

            let bounded = min(max(seconds, minSeconds), max(minSeconds, ceilingSeconds))
            if abs(bounded - seconds) > 1e-9 {
                clampedDuration = true
                let residual = seconds / bounded
                seconds = bounded
                shotISO = Float(Double(iso) * residual)
                note = String(
                    format:
                        "exposure clamped to %.2f ms; %.2f EV moved to ISO, so this frame's noise "
                        + "differs from the others'", bounded * 1000, log2(residual))
            }
            if shotISO > format.maxISO || shotISO < format.minISO {
                clampedISO = true
                shotISO = min(max(shotISO, format.minISO), format.maxISO)
                note = (note.map { $0 + "; " } ?? "")
                    + "ISO also clamped — the requested EV separation was NOT achieved"
            }

            return PlannedShot(
                evBias: ev,
                duration: CMTimeMakeWithSeconds(seconds, preferredTimescale: 1_000_000_000),
                iso: shotISO,
                clampedDuration: clampedDuration,
                clampedISO: clampedISO,
                note: note)
        }
    }

    /// The intended path (§3.4).
    ///
    /// R3 §3 resolved the AE-versus-manual question: since exposure is locked
    /// with `setExposureModeCustom`, the bracket is built from
    /// `AVCaptureManualExposureBracketedStillImageSettings`, exactly as Apple's
    /// own AVCamManual-Swift sample does when it finds `exposureMode == .custom`.
    /// The two are designed to compose — and a single bracket may not mix the
    /// AE and manual settings types, which raises.
    private func fireBracket(
        photoOutput: AVCapturePhotoOutput,
        plan: [PlannedShot],
        shutterTimes: inout [Double],
        notes: inout [String]
    ) throws -> [AVCapturePhoto] {
        // AVFoundation rejects a bracket with no exposures in it, from `capturePhoto`
        // and therefore fatally. The callers only reach here with `plan.count > 1`, so
        // this is a guard against a future caller rather than a live bug — but the
        // cost of being wrong is the process.
        guard !plan.isEmpty else {
            notes.append("the bracket plan was empty, so no frame was requested")
            shutterTimes = []
            return []
        }
        let bracketed: [AVCaptureBracketedStillImageSettings] = plan.map {
            AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                exposureDuration: $0.duration, iso: $0.iso)
        }

        let settings = AVCapturePhotoBracketSettings(
            rawPixelFormatType: 0,
            processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg],
            bracketedSettings: bracketed)
        // The output's ceiling is raised in `configureFormat` and reported back to
        // Dart as `captureSize`, but the *settings* carry their own default — the
        // active format's description dimensions — so without this the delivered
        // JPEG can be smaller than the size the intrinsics were derived for. That
        // is a pure focal error, and bundle adjustment does not absorb focal
        // errors. The native decode-size check now catches it; this stops it
        // happening.
        if #available(iOS 16.0, *), let ceiling = settingsPhotoCeiling(photoOutput) {
            settings.maxPhotoDimensions = ceiling
        }
        // Directly reduces the inter-frame shift Phase 05 §3 then has to
        // correct, so it is taken wherever it is offered.
        if photoOutput.isLensStabilizationDuringBracketedCaptureSupported {
            settings.isLensStabilizationEnabled = true
        }
        settings.photoQualityPrioritization = .quality
        if #available(iOS 14.1, *) {
            settings.isAutoContentAwareDistortionCorrectionEnabled = false
        }

        // The completion signals; it does **not** write anything the caller owns.
        //
        // It used to assign this frame's `captured`/`times` locals from the delegate's
        // queue. That is safe only while the wait below succeeds — the semaphore
        // provides the barrier — and it is not safe on the timeout path, where the
        // caller carries on reading exactly the arrays a late delegate is still
        // writing. A data race on a Swift `Array` is heap corruption rather than a
        // trap, so it is timing-dependent and shows up in an optimised build first,
        // which is the shape of the reported release-only crash.
        //
        // The delegate already keeps its own copy under an `NSLock`, so the fix is to
        // read from there once the wait is over, timeout or not.
        let semaphore = DispatchSemaphore(value: 0)
        let delegate = PhotoCaptureDelegate(expected: plan.count) { _, _ in
            semaphore.signal()
        }
        retainedDelegates.append(delegate)
        photoOutput.capturePhoto(with: settings, delegate: delegate)
        if semaphore.wait(timeout: .now() + 20.0) == .timedOut {
            notes.append("the bracket did not deliver all \(plan.count) frames within 20 s")
        }
        retainedDelegates.removeAll { $0 === delegate }
        shutterTimes = delegate.shutterTimesSoFar()
        return delegate.photosSoFar()
    }

    /// The fallback R3 §4 asks for when the device grants fewer bracket slots
    /// than the plan needs — and the only path on a device with no bracketing
    /// at all. Slower, and the frames are further apart in time, which matters
    /// for ghosting; said so rather than glossed.
    private func fireSequential(
        device: AVCaptureDevice,
        photoOutput: AVCapturePhotoOutput,
        plan: [PlannedShot],
        shutterTimes: inout [Double],
        notes: inout [String]
    ) throws -> [AVCapturePhoto] {
        if plan.count > 1 {
            notes.append(
                "fired \(plan.count) sequential single shots rather than one bracket; the frames "
                    + "are further apart in time than a burst, which matters for ghosting")
        }
        var captured: [AVCapturePhoto] = []
        var times: [Double] = []

        for shot in plan {
            applyCustomExposure(device: device, duration: shot.duration, iso: shot.iso)

            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            // Same reason as the bracket path: the settings default to the active
            // format's dimensions, not the raised ceiling the intrinsics assume.
            if #available(iOS 16.0, *), let ceiling = settingsPhotoCeiling(photoOutput) {
                settings.maxPhotoDimensions = ceiling
            }
            settings.photoQualityPrioritization = .quality
            if #available(iOS 14.1, *) {
                settings.isAutoContentAwareDistortionCorrectionEnabled = false
            }

            // Same reasoning as the bracket, and worse here: a delegate left over from
            // a timed-out iteration would be appending to the very arrays the next
            // iteration's delegate is appending to. Two queues mutating one Swift
            // `Array` corrupts the heap. The delegate accumulates under its own lock
            // and the caller collects afterwards.
            let semaphore = DispatchSemaphore(value: 0)
            let delegate = PhotoCaptureDelegate(expected: 1) { _, _ in
                semaphore.signal()
            }
            retainedDelegates.append(delegate)
            photoOutput.capturePhoto(with: settings, delegate: delegate)
            _ = semaphore.wait(timeout: .now() + 10.0)
            retainedDelegates.removeAll { $0 === delegate }
            captured.append(contentsOf: delegate.photosSoFar())
            times.append(contentsOf: delegate.shutterTimesSoFar())
        }

        // Restore the session lock, or every later position would inherit the last
        // frame's exposure — but **only if there was ever a lock to restore**.
        //
        // This line was the release-build crash. `baseDuration`/`baseISO` are set in
        // exactly one place, `meterAndLock`, and `ExposureStrategy.auto` never calls
        // it, so on the default configuration they were still `CMTime.zero` and `0`
        // when the shutter fired. `setExposureModeCustom` raises `NSRangeException`
        // for a value outside the active format's range, Swift cannot catch an
        // Objective-C exception, and the app died on the first capture.
        //
        // It was latent until `configFrom` stopped forcing `bracket3`/`locked` — those
        // always metered first, so they always set these. Making `auto` the default
        // reached it. `applyCustomExposure` would now refuse a zero duration anyway;
        // the guard is here as well because restoring a lock that was never taken is
        // meaningless on its own terms. On the auto path the device stays in
        // `.continuousAutoExposure`, which is what it was metering with all along.
        if lockQuality != .unlocked {
            applyCustomExposure(device: device, duration: baseDuration, iso: baseISO)
        }

        shutterTimes = times
        return captured
    }

    // MARK: - misc

    func sampleClockOffset() -> ClockOffsetSample {
        (mapper ?? TimestampMapper()).sample()
    }

    func close() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        retainedDelegates.removeAll()
        videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        session = nil
        photoOutput = nil
        videoOutput = nil
        device = nil
        if let id = textureId { onPlatformThread { self.textures.unregisterTexture(id) } }
        textureId = nil
        previewTexture = nil
        mapper = nil
        isLocked = false

        intrinsicsLock.lock()
        observedIntrinsicMatrix = nil
        observedIntrinsicReference = nil
        intrinsicAttachmentArrived = false
        framesSeen = 0
        intrinsicsLock.unlock()
    }

    /// §7 pitfall 3: on iPad a second app taking the camera is common — split
    /// view, a call, Control Centre. Surfaced rather than left to look like a
    /// frozen preview.
    private func registerInterruptionObservers(session: AVCaptureSession) {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main
            ) { [weak self] note in
                let reasonValue =
                    note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? -1
                self?.onInterruption(true, CameraSessionIOS.interruptionReason(reasonValue))
            })
        observers.append(
            center.addObserver(
                forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main
            ) { [weak self] _ in
                self?.onInterruption(false, "the interruption ended")
            })
        observers.append(
            center.addObserver(
                forName: .AVCaptureSessionRuntimeError, object: session, queue: .main
            ) { [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self?.onAsyncError(
                    "session_runtime_error", error?.localizedDescription ?? "unknown runtime error")
            })
    }

    private static func interruptionReason(_ raw: Int) -> String {
        guard let reason = AVCaptureSession.InterruptionReason(rawValue: raw) else {
            return "unknown reason \(raw)"
        }
        switch reason {
        case .videoDeviceNotAvailableInBackground: return "the app went to the background"
        case .audioDeviceInUseByAnotherClient: return "another app took the microphone"
        case .videoDeviceInUseByAnotherClient: return "another app took the camera"
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return "the camera is unavailable in split view or Slide Over"
        case .videoDeviceNotAvailableDueToSystemPressure:
            return "the camera was suspended because the device is under system pressure"
        @unknown default: return "unknown reason \(raw)"
        }
    }

    /// Blocks until the camera permission is settled, then throws if it was
    /// refused.
    ///
    /// Blocking is safe because every host method already runs on the plugin's
    /// serial queue, never on the platform thread. The prompt itself is the
    /// system's, and it appears on first request — so an integration-test run on
    /// a freshly installed app will sit here until someone taps Allow, which is
    /// the honest behaviour and is called out in `RUNNING.md`.
    private func requireCameraAuthorization() throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .video) { allowed in
                granted = allowed
                semaphore.signal()
            }
            // Generous: the user has to read a dialog and tap it.
            if semaphore.wait(timeout: .now() + 60) == .timedOut {
                throw PigeonError(
                    code: "camera_permission_timeout",
                    message: "the camera permission prompt was not answered within 60 s",
                    details: nil)
            }
            if !granted {
                throw PigeonError(
                    code: "camera_permission_denied",
                    message: "camera access was refused",
                    details: nil)
            }
        case .denied, .restricted:
            throw PigeonError(
                code: "camera_permission_denied",
                message:
                    "camera access is denied or restricted for this app. Enable it in "
                    + "Settings › Privacy & Security › Camera.",
                details: nil)
        @unknown default:
            throw PigeonError(
                code: "camera_permission_unknown",
                message: "the camera authorisation status is unrecognised",
                details: nil)
        }
    }

    private func findDevice(uniqueID: String) -> AVCaptureDevice? {
        var types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .builtInTelephotoCamera, .builtInUltraWideCamera,
            .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera,
        ]
        if #available(iOS 15.4, *) { types.append(.builtInLiDARDepthCamera) }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        ).devices.first { $0.uniqueID == uniqueID }
    }

    private func photoSizes(for device: AVCaptureDevice) -> [CMVideoDimensions] {
        device.formats.map { largestPhotoSize(for: $0) }
            .sorted { Int($0.width) * Int($0.height) > Int($1.width) * Int($1.height) }
    }

    private func photoSizes(forFormat format: AVCaptureDevice.Format) -> [CMVideoDimensions] {
        if #available(iOS 16.0, *) {
            let supported = format.supportedMaxPhotoDimensions
            if !supported.isEmpty { return supported }
        }
        return [largestPhotoSize(for: format)]
    }

    private func largestPhotoSize(for format: AVCaptureDevice.Format) -> CMVideoDimensions {
        if #available(iOS 16.0, *) {
            if let largest = format.supportedMaxPhotoDimensions.max(by: {
                Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
            }) {
                return largest
            }
        }
        return CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    }

    private func isFourThree(_ size: PlatformSize) -> Bool {
        let long = Double(max(size.width, size.height))
        let short = Double(min(size.width, size.height))
        guard short > 0 else { return false }
        return abs(long / short - 4.0 / 3.0) < 0.02
    }

    /// `simd_float3x3` is column-major; the wire format and OpenCV are both
    /// row-major. Transposing here rather than at the far end keeps the one
    /// place that knows about `simd` next to the one place that reads it.
    private func rowMajor(_ m: matrix_float3x3) -> [Double] {
        [
            Double(m.columns.0.x), Double(m.columns.1.x), Double(m.columns.2.x),
            Double(m.columns.0.y), Double(m.columns.1.y), Double(m.columns.2.y),
            Double(m.columns.0.z), Double(m.columns.1.z), Double(m.columns.2.z),
        ]
    }
}

// MARK: - preview + tier-2 intrinsics

extension CameraSessionIOS: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            previewTexture?.setPixelBuffer(buffer)
            if let id = textureId { textures.textureFrameAvailable(id) }
        }

        if let mapper = mapper {
            onPreviewFrame(mapper.toMotionClockUs(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
        }

        // Tier 2 of Math §4.2. The question is not whether
        // `isCameraIntrinsicMatrixDeliverySupported` is true — it has said true
        // on devices that never delivered anything, which is why R2 lists this
        // as the top empirical unknown. The question is whether the attachment
        // shows up on a real frame, and this is where that is answered.
        intrinsicsLock.lock()
        framesSeen += 1
        if let raw = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            attachmentModeOut: nil) as? Data
        {
            let matrix: matrix_float3x3 = raw.withUnsafeBytes { $0.load(as: matrix_float3x3.self) }
            observedIntrinsicMatrix = rowMajor(matrix)
            // The matrix is stated for the buffer it arrived with, which is the
            // scaled preview buffer rather than the still. Recording the
            // dimensions alongside is what lets the resolver rescale it
            // correctly instead of silently applying a preview focal to a 12 MP
            // frame.
            if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                observedIntrinsicReference = PlatformSize(
                    width: Int64(CVPixelBufferGetWidth(buffer)),
                    height: Int64(CVPixelBufferGetHeight(buffer)))
            }
            intrinsicAttachmentArrived = true
        }
        intrinsicsLock.unlock()
    }
}

// MARK: - photo delegate

/// Collects one capture's photos and the host-clock instant of each shutter.
///
/// Shutter times come from `willCapturePhotoFor`, which separates what the
/// sensor sustains from what processing then costs — the distinction R3 §9 says
/// the JPEG-versus-YUV decision turns on, and the one a single wall-clock
/// number cannot show.
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {

    private let expected: Int
    private let completion: ([AVCapturePhoto], [Double]) -> Void
    private let lock = NSLock()
    private var photos: [AVCapturePhoto] = []
    private var shutterTimes: [Double] = []
    private var finished = false

    init(expected: Int, completion: @escaping ([AVCapturePhoto], [Double]) -> Void) {
        self.expected = expected
        self.completion = completion
        super.init()
    }

    func photosSoFar() -> [AVCapturePhoto] {
        lock.lock()
        defer { lock.unlock() }
        return photos
    }

    func shutterTimesSoFar() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return shutterTimes
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        lock.lock()
        shutterTimes.append(TimestampMapper.hostTimeSeconds())
        lock.unlock()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        lock.lock()
        if error == nil { photos.append(photo) }
        let done = photos.count >= expected && !finished
        if done { finished = true }
        let snapshot = photos
        let times = shutterTimes
        lock.unlock()
        if done { completion(snapshot, times) }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        lock.lock()
        let done = !finished
        if done { finished = true }
        let snapshot = photos
        let times = shutterTimes
        lock.unlock()
        if done { completion(snapshot, times) }
    }
}

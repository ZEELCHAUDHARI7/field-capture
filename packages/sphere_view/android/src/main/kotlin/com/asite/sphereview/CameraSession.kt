package com.asite.sphereview

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureFailure
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.ColorSpaceTransform
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.RggbChannelVector
import android.hardware.camera2.params.SessionConfiguration
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Size
import android.view.Surface
import androidx.core.content.ContextCompat
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * One Camera2 session: open, meter, lock, bracket, close.
 *
 * **Camera2, not CameraX**, per R3 §10 confirmed against CameraX 1.5 (November
 * 2025): there is still no first-class bracketing API, manual exposure is only
 * reachable through the `Camera2Interop` escape hatch with the same gating, and
 * `ExtensionMode.HDR` returns a single already-fused, tone-mapped image with no
 * per-frame control — which reintroduces exactly the photometric inconsistency
 * between panorama positions that the locked-exposure design exists to prevent.
 *
 * Every method here blocks and must be called off the camera handler thread;
 * `SphereCameraHostApiImpl` owns the executor that does that.
 */
@SuppressLint("MissingPermission")
class CameraSession(
    private val context: Context,
    private val textures: TextureRegistry,
    private val onPreviewFrame: (Long) -> Unit,
    private val onAsyncError: (String, String) -> Unit,
) {

    companion object {
        private const val OPEN_TIMEOUT_MS = 8_000L

        /**
         * Ceiling on a hop to the platform thread. Generous — it is only ever
         * reached if the UI thread is wedged, and in that case a clear timeout
         * naming the platform thread beats a capture that hangs forever.
         */
        private const val MAIN_THREAD_TIMEOUT_MS = 5_000L
        private const val SESSION_TIMEOUT_MS = 8_000L
        private const val BURST_TIMEOUT_MS = 20_000L
        private const val LOCK_SETTLE_FRAMES = 4

        /**
         * The longest exposure the bracket will lengthen *to*, ~1/60 s.
         *
         * §2.4: "if the required time exceeds the motion-blur limit (~1/60 s),
         * clamp it and take the remaining stops from ISO". Applied only as a
         * ceiling the bracket may not push past — never to shorten the base
         * exposure the metering sweep chose. A dim interior legitimately meters
         * longer than 1/60 s, and clamping the 0 EV frame to satisfy a rule
         * about the +2 EV frame would trade the whole session's noise floor for
         * nothing.
         */
        private const val MOTION_BLUR_LIMIT_NS = 16_666_666L

        /** Nearest focus the session will lock to, in metres. */
        private const val NEAREST_LOCKED_FOCUS_M = 1.5

        /** Farthest focus the session will lock to, in metres. */
        private const val FARTHEST_LOCKED_FOCUS_M = 3.0

        /**
         * Where in the observed exposure distribution to lock (§2.3 step 3).
         *
         * Interiors are mostly mid-tone with a few very bright windows, so the
         * brightness distribution is right-skewed. A *mean* sits well above the
         * bulk of it, meters for the windows, and crushes the interior. A
         * percentile is robust to those outliers; 0.65 rather than 0.50 keeps a
         * deliberate lean toward protecting highlights without letting three
         * bright frames decide the session.
         */
        private const val EXPOSURE_PERCENTILE = 0.65
    }

    private val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    private val thread = HandlerThread("sphere-camera").apply { start() }
    private val handler = Handler(thread.looper)
    private val executor = Executor { r -> handler.post(r) }

    /**
     * The platform (main) thread, for the one part of this class that may not
     * run anywhere else.
     *
     * Flutter's `TextureRegistry` is main-thread-only, and not merely by
     * convention: `createSurfaceTexture()` ends in
     * `SurfaceTexture.setOnFrameAvailableListener(listener, new Handler())` — a
     * bare `Handler`, which takes the *calling* thread's Looper. Everything in
     * this class runs on the plugin's single-threaded `sphere-camera-ops`
     * executor, which is a plain `Thread` with no Looper, so the call threw
     *
     *   Can't create handler inside thread Thread[sphere-camera-ops,5,main]
     *   that has not called Looper.prepare()
     *
     * and the plugin's `run()` wrapper relabelled it `open_failed`, which sent
     * everyone looking at the camera rather than at the texture.
     */
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Runs [block] on the platform thread and returns its value.
     *
     * Blocking the operations thread on the main thread is safe here and only
     * here: the Pigeon entry points hand work to the executor and return
     * immediately, so the platform thread is never itself waiting on this one.
     * Called from the platform thread it runs inline, so a future caller that
     * is already there cannot deadlock on itself.
     */
    private fun <T> onMainThread(block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val latch = CountDownLatch(1)
        var value: T? = null
        var failure: Throwable? = null
        mainHandler.post {
            try {
                value = block()
            } catch (t: Throwable) {
                failure = t
            } finally {
                latch.countDown()
            }
        }
        if (!latch.await(MAIN_THREAD_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            throw FlutterError(
                "main_thread_timeout",
                "the platform thread did not respond within " +
                    "$MAIN_THREAD_TIMEOUT_MS ms while setting up the preview texture",
                null,
            )
        }
        failure?.let { throw it }
        @Suppress("UNCHECKED_CAST")
        return value as T
    }

    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var characteristics: CameraCharacteristics? = null

    private var captureReader: ImageReader? = null
    /**
     * The preview texture, as a `SurfaceProducer` rather than the deprecated
     * `SurfaceTextureEntry`.
     *
     * The migration is not tidying. `SurfaceTextureEntry` is the legacy GL path,
     * and that path applies the `SurfaceTexture` transform matrix — crop *and*
     * rotation — on its way to the canvas. So the buffer Flutter drew was already
     * upright, and a Dart-side `RotatedBox` computed from `SENSOR_ORIENTATION`
     * turned a correct preview into a sideways one. The device says
     * `SENSOR_ORIENTATION = 90` and the display says `ROTATION_0`, so every
     * derivation agreed on "one quarter turn" and every one of them was answering
     * the wrong question.
     *
     * `SurfaceProducer` exposes [TextureRegistry.SurfaceProducer.handlesCropAndRotation],
     * which is the question actually worth asking, and the engine documents why it
     * has to be asked rather than assumed: on API 29+ an `ImageReader` backend is
     * used, and that one does **not** handle the metadata. So the same code has to
     * rotate on one device and not on another, and only the platform knows which.
     */
    private var previewProducer: TextureRegistry.SurfaceProducer? = null
    private var previewSurface: Surface? = null

    /**
     * Whether the render path turns the preview buffer for us.
     *
     * Reported to Dart as part of [CameraOpenResult] so the decision is a fact the
     * platform stated rather than something Dart inferred from image dimensions —
     * and so a bug report says which backend the device used.
     */
    private var previewHandlesRotation = false

    /**
     * The lifecycle `SurfaceTextureEntry` did not have.
     *
     * A `SurfaceProducer`'s surface is released when the app goes to the background
     * and a *different* one is handed back on resume, so a capture session holding
     * the old `Surface` as a target would resume rendering into nothing. The
     * `SurfaceTexture` path never surfaced this because the engine kept the texture
     * alive across the transition; taking the newer API means taking its lifecycle
     * with it.
     *
     * The response is the one the class already has for losing the camera: report
     * it and let the session above decide. Rebuilding the capture session from in
     * here would race everything else on the ops thread, and a capture that
     * silently resumed against a dead surface is worse than one that says it was
     * interrupted — the operator can resume a bundle, and §7's whole
     * interrupted-site-walk design exists for exactly this.
     */
    private val previewCallback =
        object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                // A new surface, so the old target is stale. Nothing to do if the
                // session was never built; if it was, it has to be told.
                if (previewSurface != null) {
                    onAsyncError(
                        "preview_surface_recreated",
                        "the preview surface was recreated after the app returned to the " +
                            "foreground; the capture session has to be reopened",
                    )
                }
            }

            override fun onSurfaceCleanup() {
                // Dropped here rather than released: the producer owns it, and
                // releasing a Surface the engine still holds is a crash on some
                // drivers.
                previewSurface = null
            }
        }

    private var captureSize: Size = Size(0, 0)
    private var previewSize: Size = Size(0, 0)
    private var captureFormat: Int = ImageFormat.JPEG
    private var deferredEncode = false
    private var jpegQuality = 95
    private var computeStatistics = false

    private var hasManualSensor = false
    private var hasManualPostProcessing = false
    private var bracketMode = PlatformBracketMode.SINGLE_SHOT

    private var mapper: TimestampMapper? = null
    private var lock: LockedExposure? = null

    @Volatile private var burst: BurstCollector? = null

    /**
     * The exposure state the whole session is frozen at, plus the evidence for
     * how it was chosen.
     *
     * [meanEv] rides along next to [percentileEv] so §2.3's decision is visible
     * in the data rather than only in the code: if the two are far apart, the
     * scene really did have the bright-window skew the percentile exists to
     * resist, and anyone reading a bundle later can see that.
     */
    private data class LockedExposure(
        val exposureNs: Long,
        val iso: Int,
        val focusDistance: Float?,
        val awbGains: RggbChannelVector?,
        val awbTransform: ColorSpaceTransform?,
        val quality: PlatformLockQuality,
        /** Set while the locked request is built, since it depends on what the HAL offers. */
        var pinnedProcessing: Boolean,
        val chosenEv: Double,
        val meanEv: Double,
        val percentileEv: Double,
    )

    // ------------------------------------------------------------- open --

    fun open(cameraId: String, request: CaptureFormatRequest): CameraOpenResult {
        close()

        // Before anything else. `openCamera` without the permission throws a
        // bare SecurityException from deep inside the framework, which reaches
        // Dart as an untyped failure nobody can branch on; the host app needs to
        // be able to tell "no permission" from "no camera" so it can prompt.
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            throw FlutterError(
                "camera_permission_denied",
                "the CAMERA permission has not been granted to this app",
                null,
            )
        }

        val c = manager.getCameraCharacteristics(cameraId)
        characteristics = c

        val caps = c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)?.toList() ?: emptyList()
        hasManualSensor = caps.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR)
        hasManualPostProcessing =
            caps.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING)

        deferredEncode = request.format == PlatformCaptureFormat.YUV_DEFERRED_JPEG
        captureFormat = if (deferredEncode) ImageFormat.YUV_420_888 else ImageFormat.JPEG
        jpegQuality = request.jpegQuality.toInt().coerceIn(1, 100)
        computeStatistics = request.computeFrameStatistics

        val map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: throw FlutterError("no_stream_map", "camera $cameraId reports no stream configuration map", null)

        val warnings = mutableListOf<String>()

        captureSize = pickCaptureSize(map.getOutputSizes(captureFormat), request, warnings)
        val fourThree = CameraFacts.isFourThree(captureSize)
        if (!fourThree && request.preferFourThree) {
            // §2.1's preference is not cosmetic: a 4:3 stream off a 4:3 array is
            // a pure scale, so no crop term enters the intrinsics, and it gives
            // the largest vertical FOV, which directly reduces the ring count.
            warnings.add(
                "no 4:3 capture size available; using ${captureSize.width}x${captureSize.height}, " +
                    "which is a crop of the sensor array — the intrinsics derivation picks up a " +
                    "crop term and the vertical field of view is smaller than this camera can give"
            )
        }

        previewSize =
            CameraFacts.previewSize(
                map.getOutputSizes(SurfaceTexture::class.java),
                request.previewTargetWidth.toInt(),
                captureSize.width.toDouble() / captureSize.height,
            )

        // maxImages must exceed the burst length: the HAL runs ahead, and a
        // reader that runs out of buffers stalls the pipeline after a few
        // frames — §7 pitfall 4, which with 87 frames fails fast and looks like
        // a hardware fault.
        captureReader =
            ImageReader.newInstance(
                captureSize.width,
                captureSize.height,
                captureFormat,
                CameraFacts.MAX_BURST_LENGTH + 2,
            ).also { reader ->
                reader.setOnImageAvailableListener({ r -> drainCaptureReader(r) }, handler)
            }

        // The preview texture is created here rather than in attachPreview(),
        // so its Surface is part of the session from the start. §7 pitfall 1 is
        // that captureBurst fails silently if the session is reconfigured, and
        // the surest way to honour that is to have nothing left to reconfigure.
        val producer = onMainThread {
            textures.createSurfaceProducer().also {
                it.setSize(previewSize.width, previewSize.height)
                it.setCallback(previewCallback)
            }
        }
        previewProducer = producer
        previewHandlesRotation = onMainThread { producer.handlesCropAndRotation() }
        previewSurface = onMainThread { producer.getSurface() }

        device = openDevice(cameraId)
        session = createSession(device!!, listOf(previewSurface!!, captureReader!!.surface))

        mapper = TimestampMapper.forCamera(c)

        bracketMode =
            when {
                hasManualSensor -> PlatformBracketMode.MANUAL_EXPOSURE_BURST
                hasUsableAeCompensation(c) -> PlatformBracketMode.AE_COMPENSATION_BURST
                else -> PlatformBracketMode.SINGLE_SHOT
            }
        if (bracketMode != PlatformBracketMode.MANUAL_EXPOSURE_BURST) {
            warnings.add(
                "MANUAL_SENSOR is absent (hardware level " +
                    "${CameraFacts.hardwareLevel(c).name}), so exposure cannot be set per " +
                    "request. Falling back to ${bracketMode.name} — which is not a true bracket " +
                    "and must not be read as one."
            )
        }

        // Start the preview running immediately so AE/AWB/AF have something to
        // converge on before meterAndLock is called.
        startPreview(auto = true)

        val supportsDistortionOff = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
        return CameraOpenResult(
            captureSize = PlatformSize(captureSize.width.toLong(), captureSize.height.toLong()),
            previewSize = PlatformSize(previewSize.width.toLong(), previewSize.height.toLong()),
            sensorOrientationDegrees =
                (c.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0).toLong(),
            // The whole point of asking the producer: `0` when the render path
            // already turned the buffer, the mounting angle when it did not.
            //
            // No display-rotation term. The general formula is
            // `(sensorOrientation - displayRotation + 360) % 360`, and the capture
            // screen is portrait-locked (`SphereCaptureView` sets `portraitUp`
            // only), so that term is always zero. Reading it from a
            // `WindowManager` would add a dependency and a main-thread hop to
            // compute a constant, and would go stale the moment the lock changed
            // without this being updated with it.
            previewRotationDegrees =
                if (previewHandlesRotation) {
                    0L
                } else {
                    (((c.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0) % 360 + 360) % 360)
                        .toLong()
                },
            previewHandlesRotation = previewHandlesRotation,
            clock = mapper!!.toInfo(),
            bracketMode = bracketMode,
            maxBracketCount =
                when (bracketMode) {
                    PlatformBracketMode.MANUAL_EXPOSURE_BURST -> CameraFacts.MAX_BURST_LENGTH.toLong()
                    PlatformBracketMode.AE_COMPENSATION_BURST -> 3L
                    else -> 1L
                },
            captureAspectIsFourThree = fourThree,
            androidFacts =
                CameraFacts.intrinsicFacts(
                    c,
                    cropRegion = null,
                    distortionCorrectionOffRequested = supportsDistortionOff,
                ),
            iosFacts = null,
            warning = if (warnings.isEmpty()) null else warnings.joinToString("; "),
        )
    }

    private fun pickCaptureSize(
        sizes: Array<Size>?,
        request: CaptureFormatRequest,
        warnings: MutableList<String>,
    ): Size {
        val available = sizes?.toList().orEmpty()
        if (available.isEmpty()) {
            throw FlutterError("no_capture_sizes", "camera offers no sizes for the capture format", null)
        }
        val requested = request.captureSize
        if (requested != null) {
            val match =
                available.firstOrNull {
                    it.width == requested.width.toInt() && it.height == requested.height.toInt()
                }
            if (match != null) return match
            warnings.add(
                "requested capture size ${requested.width}x${requested.height} is not offered " +
                    "for this format; picked the largest 4:3 instead"
            )
        }
        return CameraFacts.largestFourThree(available.toTypedArray()) ?: available.first()
    }

    // ---------------------------------------------------------- preview --

    fun attachPreview(): Long =
        previewProducer?.id() ?: throw FlutterError("not_open", "the camera is not open", null)

    fun detachPreview() {
        // Deliberately does not tear the Surface out of the session — see the
        // note in open(). Stopping the repeating request is what actually stops
        // the work.
        session?.let { runCatching { it.stopRepeating() } }
    }

    // ---------------------------------------------------- meter and lock --

    fun meterAndLock(durationSeconds: Double): MeteringResult {
        val c = characteristics ?: throw FlutterError("not_open", "the camera is not open", null)
        val s = session ?: throw FlutterError("not_open", "the camera is not open", null)

        val samples = mutableListOf<TotalCaptureResult>()
        val collecting = Object()
        var converged = false

        // §2.3 step 1–2: full auto, and let the user pan the sphere while every
        // converged AE result is recorded. Locking on the first frame instead
        // would meter whichever wall the user happens to be facing.
        val builder = s.device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
        builder.addTarget(previewSurface!!)
        builder.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
        builder.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
        builder.set(CaptureRequest.CONTROL_AE_LOCK, false)
        builder.set(CaptureRequest.CONTROL_AWB_MODE, CameraMetadata.CONTROL_AWB_MODE_AUTO)
        builder.set(CaptureRequest.CONTROL_AWB_LOCK, false)
        builder.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
        applyInvariantRequestKeys(builder)

        s.setRepeatingRequest(
            builder.build(),
            object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(
                    cs: CameraCaptureSession,
                    request: CaptureRequest,
                    result: TotalCaptureResult,
                ) {
                    emitPreviewTimestamp(result)
                    synchronized(collecting) {
                        samples.add(result)
                        val ae = result.get(CaptureResult.CONTROL_AE_STATE)
                        if (ae == CaptureResult.CONTROL_AE_STATE_CONVERGED ||
                            ae == CaptureResult.CONTROL_AE_STATE_LOCKED
                        ) {
                            converged = true
                        }
                    }
                }
            },
            handler,
        )

        Thread.sleep((durationSeconds.coerceIn(0.2, 20.0) * 1000).toLong())

        val observed: List<TotalCaptureResult>
        synchronized(collecting) { observed = samples.toList() }

        val notes = mutableListOf<String>()
        val plan = choosePlan(c, observed, notes)

        val quality = applyLock(s, plan, notes)
        lock = plan.copy(quality = quality)

        return MeteringResult(
            exposureTimeNs = plan.exposureNs,
            iso = plan.iso.toLong(),
            // Camera2 exposes no correlated colour temperature. What is actually
            // locked is the RGGB gain vector plus the colour transform, and
            // inventing a Kelvin number from those would be a guess dressed as a
            // measurement. Reported as 0 with the note below instead.
            colorTemperatureK = 0L,
            focusDistanceDiopters = (plan.focusDistance ?: 0f).toDouble(),
            lockQuality = quality,
            sampleCount = observed.size.toLong(),
            chosenEv = plan.chosenEv,
            meanEv = plan.meanEv,
            percentile65Ev = plan.percentileEv,
            aeConverged = converged,
            pinnedProcessingModes = plan.pinnedProcessing,
            note =
                (notes +
                    "Camera2 reports no correlated colour temperature; the locked white balance " +
                    "is the RGGB gain vector and colour transform, not a Kelvin value")
                    .joinToString("; "),
        )
    }

    /** The metering sweep's decision, before it has been applied. */
    private fun choosePlan(
        c: CameraCharacteristics,
        observed: List<TotalCaptureResult>,
        notes: MutableList<String>,
    ): LockedExposure {
        val expRange = c.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
        val isoRange = c.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)

        val products =
            observed.mapNotNull { r ->
                val e = r.get(CaptureResult.SENSOR_EXPOSURE_TIME)
                val i = r.get(CaptureResult.SENSOR_SENSITIVITY)
                if (e == null || i == null || e <= 0 || i <= 0) null else e.toDouble() * i
            }

        val last = observed.lastOrNull()
        if (products.isEmpty()) {
            notes.add(
                "the metering sweep produced no usable SENSOR_EXPOSURE_TIME/SENSITIVITY results, " +
                    "so the lock is whatever the last frame reported"
            )
            val fallbackExp =
                last?.get(CaptureResult.SENSOR_EXPOSURE_TIME)
                    ?: expRange?.lower?.coerceAtLeast(1_000_000L)
                    ?: 16_666_666L
            val fallbackIso = last?.get(CaptureResult.SENSOR_SENSITIVITY) ?: isoRange?.lower ?: 100
            return LockedExposure(
                exposureNs = fallbackExp,
                iso = fallbackIso,
                focusDistance = chooseFocus(c, observed, notes),
                awbGains = last?.get(CaptureResult.COLOR_CORRECTION_GAINS),
                awbTransform = last?.get(CaptureResult.COLOR_CORRECTION_TRANSFORM),
                quality = PlatformLockQuality.UNLOCKED,
                pinnedProcessing = false,
                chosenEv = 0.0,
                meanEv = 0.0,
                percentileEv = 0.0,
            )
        }

        val sorted = products.sorted()
        val medianProduct = sorted[sorted.size / 2]

        // Scene brightness in stops, relative to the sweep's median frame. The
        // sensor's exposure product moves *against* scene brightness — a bright
        // window needs less light collected — hence the negation. Getting this
        // sign wrong would meter every interior for the darkest corner it saw.
        fun sceneEv(product: Double) = -ln(product / medianProduct) / ln(2.0)

        val evs = products.map(::sceneEv).sorted()
        val meanEv = evs.average()
        val index = ((evs.size - 1) * EXPOSURE_PERCENTILE).roundToInt().coerceIn(0, evs.size - 1)
        val percentileEv = evs[index]

        if (meanEv - percentileEv > 0.5) {
            notes.add(
                "the sweep's exposure distribution is skewed by " +
                    String.format(Locale.US, "%.2f", meanEv - percentileEv) +
                    " EV — bright windows are pulling the mean above the " +
                    "${(EXPOSURE_PERCENTILE * 100).toInt()}th percentile, which is exactly the " +
                    "case §2.3 says not to meter for"
            )
        }

        val targetProduct = medianProduct * 2.0.pow(-percentileEv)
        var iso = last?.get(CaptureResult.SENSOR_SENSITIVITY) ?: isoRange?.lower ?: 100
        if (isoRange != null) iso = iso.coerceIn(isoRange.lower, isoRange.upper)
        var exposureNs = (targetProduct / iso).roundToLong().coerceAtLeast(1L)
        if (expRange != null) {
            val clamped = exposureNs.coerceIn(expRange.lower, expRange.upper)
            if (clamped != exposureNs) {
                // Move whatever the shutter cannot take into ISO, so the chosen
                // exposure value is still reached even though the split changed.
                val residual = exposureNs.toDouble() / clamped
                exposureNs = clamped
                iso = (iso * residual).roundToInt()
                if (isoRange != null) iso = iso.coerceIn(isoRange.lower, isoRange.upper)
                notes.add(
                    "the chosen exposure fell outside the sensor's range and the residual moved " +
                        "to ISO $iso"
                )
            }
        }

        return LockedExposure(
            exposureNs = exposureNs,
            iso = iso,
            focusDistance = chooseFocus(c, observed, notes),
            awbGains = last?.get(CaptureResult.COLOR_CORRECTION_GAINS),
            awbTransform = last?.get(CaptureResult.COLOR_CORRECTION_TRANSFORM),
            quality = PlatformLockQuality.UNLOCKED,
            pinnedProcessing = false,
            chosenEv = percentileEv,
            meanEv = meanEv,
            percentileEv = percentileEv,
        )
    }

    /**
     * §2.3: lock focus near the hyperfocal distance, seeded by what continuous
     * AF actually settled on during the sweep.
     *
     * Locking to infinity softens near objects and locking to macro ruins
     * everything else, so the observed value is clamped into a 1.5–3 m window.
     * 1.5 m is the same number architecture §3 already asks users to stand off
     * to keep parallax down, which makes it the nearest distance the capture
     * technique is supposed to produce; 3 m is far enough to keep the rest of a
     * room acceptably sharp without being infinity.
     *
     * When the lens reports `UNCALIBRATED` focus distance the diopter number is
     * not on a real scale, so clamping it would be arithmetic on an arbitrary
     * unit. In that case the observed value is used untouched and said so.
     */
    private fun chooseFocus(
        c: CameraCharacteristics,
        observed: List<TotalCaptureResult>,
        notes: MutableList<String>,
    ): Float? {
        val focused =
            observed.lastOrNull { r ->
                val af = r.get(CaptureResult.CONTROL_AF_STATE)
                af == CaptureResult.CONTROL_AF_STATE_PASSIVE_FOCUSED ||
                    af == CaptureResult.CONTROL_AF_STATE_FOCUSED_LOCKED
            } ?: observed.lastOrNull()
        val observedDistance = focused?.get(CaptureResult.LENS_FOCUS_DISTANCE) ?: return null

        val calibration = c.get(CameraCharacteristics.LENS_INFO_FOCUS_DISTANCE_CALIBRATION)
        if (calibration == CameraMetadata.LENS_INFO_FOCUS_DISTANCE_CALIBRATION_UNCALIBRATED) {
            notes.add(
                "LENS_FOCUS_DISTANCE is UNCALIBRATED on this device, so its diopter value is not " +
                    "on a metric scale; locked to the observed value ($observedDistance) without " +
                    "clamping"
            )
            return observedDistance
        }

        val minDiopters = (1.0 / FARTHEST_LOCKED_FOCUS_M).toFloat()
        val maxDiopters = (1.0 / NEAREST_LOCKED_FOCUS_M).toFloat()
        val hardMax = c.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: maxDiopters
        val clamped = observedDistance.coerceIn(minDiopters, minOf(maxDiopters, hardMax))
        if (abs(clamped - observedDistance) > 1e-4) {
            notes.add(
                "autofocus settled at $observedDistance dioptres (" +
                    String.format(Locale.US, "%.2f", if (observedDistance > 0) 1 / observedDistance else Float.POSITIVE_INFINITY) +
                    " m); locked to $clamped instead, keeping focus inside the 1.5–3 m window " +
                    "the capture technique is built around"
            )
        }
        return clamped
    }

    /** §2.3 steps 4 and 5, then verify by watching a few frames come back. */
    private fun applyLock(
        s: CameraCaptureSession,
        plan: LockedExposure,
        notes: MutableList<String>,
    ): PlatformLockQuality {
        val builder = s.device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
        builder.addTarget(previewSurface!!)
        val quality = applyLockedKeys(builder, plan, notes)

        val latch = CountDownLatch(LOCK_SETTLE_FRAMES)
        s.setRepeatingRequest(
            builder.build(),
            object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(
                    cs: CameraCaptureSession,
                    request: CaptureRequest,
                    result: TotalCaptureResult,
                ) {
                    emitPreviewTimestamp(result)
                    latch.countDown()
                }
            },
            handler,
        )
        // §7 pitfall 6's Android analogue: the lock is not in effect until
        // frames have actually come back under it. Firing a burst before then
        // captures the tail of the previous configuration.
        latch.await(2, TimeUnit.SECONDS)
        return quality
    }

    /**
     * Keys that hold for every request the session ever issues, locked or not.
     *
     * `DISTORTION_CORRECTION_MODE_OFF` is the important one: Math §4.1 anchors
     * every coordinate to `preCorrectionActiveArraySize`, and letting the HAL
     * apply its own correction would move the pixels out from under that frame.
     * AOSP concedes the correction is imprecise in its own words — "rectangles
     * do not generally map to rectangles when corrected".
     */
    private fun applyInvariantRequestKeys(builder: CaptureRequest.Builder) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            builder.set(
                CaptureRequest.DISTORTION_CORRECTION_MODE,
                CameraMetadata.DISTORTION_CORRECTION_MODE_OFF,
            )
        }
        builder.set(
            CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
            CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_OFF,
        )
        builder.set(CaptureRequest.CONTROL_SCENE_MODE, CameraMetadata.CONTROL_SCENE_MODE_DISABLED)
        builder.set(CaptureRequest.CONTROL_EFFECT_MODE, CameraMetadata.CONTROL_EFFECT_MODE_OFF)
        // The JPEG must come off the sensor unrotated. The intrinsics resolved
        // in Dart are expressed in the capture stream's own coordinates, and a
        // HAL-applied EXIF rotation would leave the pixels and the model
        // describing different frames.
        builder.set(CaptureRequest.JPEG_ORIENTATION, 0)
        builder.set(CaptureRequest.JPEG_QUALITY, jpegQuality.toByte())
    }

    /**
     * The hard lock: AE, AWB and AF explicitly off with explicit values, plus
     * the four processing modes of §2.3 step 5.
     *
     * Step 5 is the part that is easy to skip and expensive to skip. If the
     * ISP's tonemap or noise reduction is left in an adaptive mode it varies
     * per frame with scene content, which reintroduces exactly the photometric
     * inconsistency the AE lock was taken to remove — and it does so invisibly,
     * as a gradient across the panorama rather than as a step at a seam.
     */
    private fun applyLockedKeys(
        builder: CaptureRequest.Builder,
        plan: LockedExposure,
        notes: MutableList<String>,
    ): PlatformLockQuality {
        applyInvariantRequestKeys(builder)
        builder.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)

        var aeLocked = false
        if (hasManualSensor) {
            // R3 §7: SENSOR_EXPOSURE_TIME and SENSOR_SENSITIVITY only take
            // effect with AE off; otherwise AE silently overrides them and the
            // whole bracket collapses to three identical frames.
            builder.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_OFF)
            builder.set(CaptureRequest.SENSOR_EXPOSURE_TIME, plan.exposureNs)
            builder.set(CaptureRequest.SENSOR_SENSITIVITY, plan.iso)
            builder.set(CaptureRequest.SENSOR_FRAME_DURATION, plan.exposureNs)
            aeLocked = true
        } else {
            builder.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
            builder.set(CaptureRequest.CONTROL_AE_LOCK, true)
            notes.add(
                "no MANUAL_SENSOR, so exposure is held with CONTROL_AE_LOCK rather than set " +
                    "explicitly; the platform may still re-converge"
            )
        }

        var awbLocked = false
        if (hasManualPostProcessing && plan.awbGains != null && plan.awbTransform != null) {
            builder.set(CaptureRequest.CONTROL_AWB_MODE, CameraMetadata.CONTROL_AWB_MODE_OFF)
            builder.set(
                CaptureRequest.COLOR_CORRECTION_MODE,
                CameraMetadata.COLOR_CORRECTION_MODE_TRANSFORM_MATRIX,
            )
            builder.set(CaptureRequest.COLOR_CORRECTION_GAINS, plan.awbGains)
            builder.set(CaptureRequest.COLOR_CORRECTION_TRANSFORM, plan.awbTransform)
            awbLocked = true
        } else {
            builder.set(CaptureRequest.CONTROL_AWB_LOCK, true)
            notes.add(
                "no MANUAL_POST_PROCESSING, so white balance is held with CONTROL_AWB_LOCK " +
                    "rather than pinned to explicit gains"
            )
        }

        var afLocked = false
        if (plan.focusDistance != null) {
            builder.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_OFF)
            builder.set(CaptureRequest.LENS_FOCUS_DISTANCE, plan.focusDistance)
            afLocked = true
        } else {
            builder.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_OFF)
            notes.add("no focus distance was observed; autofocus is off at whatever the lens holds")
        }

        val pinned = pinProcessingModes(builder, notes) && awbLocked
        plan.pinnedProcessing = pinned

        return when {
            aeLocked && awbLocked && afLocked -> PlatformLockQuality.FULLY_LOCKED
            aeLocked || awbLocked -> PlatformLockQuality.BEST_EFFORT
            else -> PlatformLockQuality.UNLOCKED
        }
    }

    /**
     * Pins noise reduction, edge enhancement and tonemap to modes the app
     * specifies rather than the HAL chooses.
     *
     * `OFF` is preferred over `FAST` for noise reduction and edge enhancement
     * because `FAST` is still the HAL's own algorithm and nothing guarantees it
     * is content-independent. For tonemap the app-specified modes are
     * `GAMMA_VALUE`, `PRESET_CURVE` and `CONTRAST_CURVE`; `FAST` and
     * `HIGH_QUALITY` are the HAL's, so landing on one of those is reported as a
     * failure to pin rather than glossed over.
     */
    private fun pinProcessingModes(
        builder: CaptureRequest.Builder,
        notes: MutableList<String>,
    ): Boolean {
        val c = characteristics ?: return false
        var allPinned = true

        val nrModes =
            c.get(CameraCharacteristics.NOISE_REDUCTION_AVAILABLE_NOISE_REDUCTION_MODES)?.toList()
                ?: emptyList()
        when {
            nrModes.contains(CameraMetadata.NOISE_REDUCTION_MODE_OFF) ->
                builder.set(
                    CaptureRequest.NOISE_REDUCTION_MODE,
                    CameraMetadata.NOISE_REDUCTION_MODE_OFF,
                )
            nrModes.contains(CameraMetadata.NOISE_REDUCTION_MODE_FAST) -> {
                builder.set(
                    CaptureRequest.NOISE_REDUCTION_MODE,
                    CameraMetadata.NOISE_REDUCTION_MODE_FAST,
                )
                notes.add("noise reduction could not be turned OFF; pinned to FAST, which is still the HAL's own algorithm")
                allPinned = false
            }
            else -> allPinned = false
        }

        val edgeModes = c.get(CameraCharacteristics.EDGE_AVAILABLE_EDGE_MODES)?.toList() ?: emptyList()
        when {
            edgeModes.contains(CameraMetadata.EDGE_MODE_OFF) ->
                builder.set(CaptureRequest.EDGE_MODE, CameraMetadata.EDGE_MODE_OFF)
            edgeModes.contains(CameraMetadata.EDGE_MODE_FAST) -> {
                builder.set(CaptureRequest.EDGE_MODE, CameraMetadata.EDGE_MODE_FAST)
                notes.add("edge enhancement could not be turned OFF; pinned to FAST")
                allPinned = false
            }
            else -> allPinned = false
        }

        val tonemapModes =
            c.get(CameraCharacteristics.TONEMAP_AVAILABLE_TONE_MAP_MODES)?.toList() ?: emptyList()
        when {
            tonemapModes.contains(CameraMetadata.TONEMAP_MODE_GAMMA_VALUE) -> {
                builder.set(CaptureRequest.TONEMAP_MODE, CameraMetadata.TONEMAP_MODE_GAMMA_VALUE)
                // 2.2 is the sRGB display gamma, which is what the rest of the
                // pipeline — and Mertens fusion in particular — assumes it is
                // looking at.
                builder.set(CaptureRequest.TONEMAP_GAMMA, 2.2f)
            }
            tonemapModes.contains(CameraMetadata.TONEMAP_MODE_PRESET_CURVE) -> {
                builder.set(CaptureRequest.TONEMAP_MODE, CameraMetadata.TONEMAP_MODE_PRESET_CURVE)
                builder.set(CaptureRequest.TONEMAP_PRESET_CURVE, CameraMetadata.TONEMAP_PRESET_CURVE_SRGB)
            }
            else -> {
                notes.add(
                    "no app-specified tonemap mode is available (GAMMA_VALUE and PRESET_CURVE are " +
                        "both absent), so the ISP keeps its own curve and may vary it per frame — " +
                        "this is the §2.3 step 5 failure, and gain compensation will have to absorb it"
                )
                allPinned = false
            }
        }

        // Lens shading correction is left ON but pinned: vignetting removal
        // genuinely helps the gain compensator, and the lens does not change,
        // so a fixed mode is deterministic frame to frame.
        val shadingModes = c.get(CameraCharacteristics.SHADING_AVAILABLE_MODES)?.toList() ?: emptyList()
        if (shadingModes.contains(CameraMetadata.SHADING_MODE_HIGH_QUALITY)) {
            builder.set(CaptureRequest.SHADING_MODE, CameraMetadata.SHADING_MODE_HIGH_QUALITY)
        } else if (shadingModes.contains(CameraMetadata.SHADING_MODE_FAST)) {
            builder.set(CaptureRequest.SHADING_MODE, CameraMetadata.SHADING_MODE_FAST)
        }

        return allPinned
    }

    fun unlock() {
        lock = null
        if (session != null) startPreview(auto = true)
    }

    private fun startPreview(auto: Boolean) {
        val s = session ?: return
        val builder = s.device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
        builder.addTarget(previewSurface!!)
        val held = lock
        if (auto || held == null) {
            builder.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
            builder.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
            builder.set(CaptureRequest.CONTROL_AWB_MODE, CameraMetadata.CONTROL_AWB_MODE_AUTO)
            builder.set(
                CaptureRequest.CONTROL_AF_MODE,
                CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_PICTURE,
            )
            applyInvariantRequestKeys(builder)
        } else {
            applyLockedKeys(builder, held, mutableListOf())
        }
        runCatching {
            s.setRepeatingRequest(
                builder.build(),
                object : CameraCaptureSession.CaptureCallback() {
                    override fun onCaptureCompleted(
                        cs: CameraCaptureSession,
                        request: CaptureRequest,
                        result: TotalCaptureResult,
                    ) {
                        emitPreviewTimestamp(result)
                    }
                },
                handler,
            )
        }
    }

    private fun emitPreviewTimestamp(result: TotalCaptureResult) {
        val raw = result.get(CaptureResult.SENSOR_TIMESTAMP) ?: return
        val m = mapper ?: return
        onPreviewFrame(m.toMotionClockUs(raw))
    }

    // ---------------------------------------------------------- bracket --

    fun captureBracket(
        evBiases: List<Double>,
        outputDirectory: String,
        namePrefix: String,
    ): CaptureResponse {
        val s = session ?: throw FlutterError("not_open", "the camera is not open", null)
        val c = characteristics ?: throw FlutterError("not_open", "the camera is not open", null)
        val m = mapper ?: throw FlutterError("not_open", "the camera is not open", null)
        val held = lock

        val dir = File(outputDirectory).apply { mkdirs() }
        val notes = mutableListOf<String>()

        val requestedBiases =
            when (if (held == null) PlatformBracketMode.SINGLE_SHOT else bracketMode) {
                PlatformBracketMode.SINGLE_SHOT -> {
                    if (evBiases.size > 1) {
                        notes.add(
                            "this device has no usable exposure control, so the ${evBiases.size}-shot " +
                                "bracket collapsed to a single frame at the metered lock"
                        )
                    }
                    listOf(0.0)
                }
                else -> evBiases.ifEmpty { listOf(0.0) }
            }

        val plan = planBracket(c, held, requestedBiases, notes)

        val builders =
            plan.shots.map { shot ->
                val b = s.device.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE)
                b.addTarget(captureReader!!.surface)
                if (held != null) {
                    applyLockedKeys(b, held, mutableListOf())
                } else {
                    applyInvariantRequestKeys(b)
                }
                // No lock means `ExposureStrategy.auto`: meter this frame on its
                // own and take one shot. Set explicitly rather than trusting
                // TEMPLATE_STILL_CAPTURE's defaults, and *before* the bracket
                // branches below, which are skipped entirely in this mode.
                //
                // Skipping them is not a tidiness point. `planBracket` falls back
                // to a hard-coded 1/60 s at ISO 100 when there is no lock to
                // derive from, so a device with MANUAL_SENSOR would have shot
                // every frame at a fixed exposure chosen for daylight — several
                // stops under in any interior, which is exactly the "some images
                // are too dark" complaint, arrived at by a different route.
                if (held == null) {
                    b.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
                    b.set(CaptureRequest.CONTROL_AE_LOCK, false)
                    b.set(CaptureRequest.CONTROL_AWB_MODE, CameraMetadata.CONTROL_AWB_MODE_AUTO)
                }
                when (if (held == null) PlatformBracketMode.SINGLE_SHOT else bracketMode) {
                    PlatformBracketMode.MANUAL_EXPOSURE_BURST -> {
                        b.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_OFF)
                        b.set(CaptureRequest.SENSOR_EXPOSURE_TIME, shot.exposureNs)
                        b.set(CaptureRequest.SENSOR_SENSITIVITY, shot.iso)
                        b.set(CaptureRequest.SENSOR_FRAME_DURATION, shot.exposureNs)
                    }
                    PlatformBracketMode.AE_COMPENSATION_BURST -> {
                        b.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
                        b.set(CaptureRequest.CONTROL_AE_LOCK, false)
                        b.set(
                            CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION,
                            shot.aeCompensationSteps,
                        )
                    }
                    else -> Unit
                }
                b.build()
            }

        val collector = BurstCollector(plan.shots.size, m)
        burst = collector

        // §7 pitfall 1: never touch the session between requests. Stopping the
        // repeating preview *before* the burst — and restarting it only after
        // every image is in hand — is the whole of that discipline.
        runCatching { s.stopRepeating() }

        val t0 = SystemClock.elapsedRealtimeNanos()
        val callback =
            object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureStarted(
                    cs: CameraCaptureSession,
                    request: CaptureRequest,
                    timestamp: Long,
                    frameNumber: Long,
                ) {
                    collector.onStarted(timestamp)
                }

                override fun onCaptureCompleted(
                    cs: CameraCaptureSession,
                    request: CaptureRequest,
                    result: TotalCaptureResult,
                ) {
                    collector.onCompleted(result)
                }

                override fun onCaptureFailed(
                    cs: CameraCaptureSession,
                    request: CaptureRequest,
                    failure: CaptureFailure,
                ) {
                    collector.onFailed("capture failed, reason ${failure.reason}")
                }
            }

        try {
            if (bracketMode == PlatformBracketMode.AE_COMPENSATION_BURST) {
                // Auto-exposure needs frames to converge on a new compensation
                // value, so submitting these as one burst would deliver three
                // frames at whatever AE happened to be doing. Fired one at a
                // time with a settle gap instead — slower, further apart in
                // time, and honestly labelled.
                notes.add(
                    "AE-compensation frames were fired sequentially with a settle gap because " +
                        "auto-exposure converges over frames; they are further apart in time than " +
                        "a real burst, which matters for ghosting"
                )
                for (request in builders) {
                    s.capture(request, callback, handler)
                    Thread.sleep(350)
                }
            } else {
                s.captureBurst(builders, callback, handler)
            }

            val delivered = collector.awaitImages(BURST_TIMEOUT_MS)
            val tLast = collector.lastImageAtNs.takeIf { it != 0L } ?: SystemClock.elapsedRealtimeNanos()
            collector.awaitMetadata(2_000)
            if (!delivered) {
                notes.add(
                    "only ${collector.receivedCount} of ${plan.shots.size} frames were delivered " +
                        "before the ${BURST_TIMEOUT_MS} ms timeout"
                )
            }

            var deferredEncodeMs = 0.0
            val frames = mutableListOf<PlatformFrame>()
            for ((index, shot) in plan.shots.withIndex()) {
                val raw = collector.payload(index) ?: continue
                val jpeg: ByteArray
                if (deferredEncode) {
                    val encodeStart = System.nanoTime()
                    // The size the HAL delivered, not the size we asked for.
                    val delivered = collector.deliveredSize(index) ?: captureSize
                    jpeg = ImageUtils.nv21ToJpeg(raw, delivered.width, delivered.height, jpegQuality)
                    deferredEncodeMs += (System.nanoTime() - encodeStart) / 1e6
                } else {
                    jpeg = raw
                }
                val file =
                    File(dir, String.format(Locale.US, "%s_%d_ev%+.2f.jpg", namePrefix, index, shot.evBias))
                file.writeBytes(jpeg)
                // The contract is that the bytes on disk are the capture frame,
                // unrotated, with a normal orientation tag. `JPEG_ORIENTATION = 0`
                // asks for that; this makes sure of it.
                ImageUtils.normaliseExifOrientation(file)

                val means = if (computeStatistics) ImageUtils.centreMeansRgb(jpeg) else null
                val result = collector.result(index)
                val actualExposure = result?.get(CaptureResult.SENSOR_EXPOSURE_TIME)
                val actualIso = result?.get(CaptureResult.SENSOR_SENSITIVITY)
                frames.add(
                    PlatformFrame(
                        filePath = file.absolutePath,
                        evBias = shot.evBias,
                        timestampUs = collector.timestampUs(index),
                        byteCount = jpeg.size.toLong(),
                        exposureTimeNs = actualExposure,
                        iso = actualIso?.toLong(),
                        // Computed from what the sensor actually did, not from
                        // what was asked for. A device with no real bracketing
                        // returns three identical frames, and this is the only
                        // place that shows up.
                        achievedEvBias =
                            if (actualExposure != null && actualIso != null && plan.baseProduct > 0) {
                                ln((actualExposure.toDouble() * actualIso) / plan.baseProduct) / ln(2.0)
                            } else {
                                null
                            },
                        meanR = means?.get(0),
                        meanG = means?.get(1),
                        meanB = means?.get(2),
                        note = shot.note,
                    )
                )
            }

            return CaptureResponse(
                frames = frames,
                burstWallClockMs = (tLast - t0) / 1e6,
                shutterToShutterMs = collector.shutterToShutterMs(),
                mode = bracketMode,
                clampedExposure = plan.clampedExposure,
                clampedIso = plan.clampedIso,
                deferredEncodeMs = deferredEncodeMs,
                note = if (notes.isEmpty()) null else notes.joinToString("; "),
            )
        } finally {
            burst = null
            startPreview(auto = lock == null)
        }
    }

    /** One frame of the bracket, resolved against the sensor's real limits. */
    private data class Shot(
        val evBias: Double,
        val exposureNs: Long,
        val iso: Int,
        val aeCompensationSteps: Int,
        val note: String?,
    )

    private data class BracketPlan(
        val shots: List<Shot>,
        val clampedExposure: Boolean,
        val clampedIso: Boolean,
        val baseProduct: Double,
    )

    /**
     * §2.4: **vary exposure time, not ISO.**
     *
     * Changing ISO between bracket frames changes the noise characteristics
     * between them, which confuses both the Mertens fusion weighting and the
     * ghost detector — Phase 05 compares frames against each other, and a
     * difference in grain reads as a difference in content. Changing time keeps
     * the noise consistent.
     *
     * ISO is only touched when exposure time hits a wall, and every such case is
     * reported: a silently clamped bracket looks like a passing capture while
     * delivering less dynamic range than the design assumes.
     */
    private fun planBracket(
        c: CameraCharacteristics,
        held: LockedExposure?,
        evBiases: List<Double>,
        notes: MutableList<String>,
    ): BracketPlan {
        val expRange = c.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
        val isoRange = c.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
        val aeStep =
            c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)
                ?.let { it.numerator.toDouble() / it.denominator } ?: (1.0 / 3.0)
        val aeRange = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)

        val baseExposure = held?.exposureNs ?: 16_666_666L
        val baseIso = held?.iso ?: 100
        // The bracket may lengthen exposure up to 1/60 s, or up to the base
        // exposure when metering already chose something longer than that in a
        // dim interior. See MOTION_BLUR_LIMIT_NS.
        val exposureCeiling = maxOf(MOTION_BLUR_LIMIT_NS, baseExposure)

        var clampedExposure = false
        var clampedIso = false

        val shots =
            evBiases.map { ev ->
                var exposure = (baseExposure * 2.0.pow(ev)).roundToLong().coerceAtLeast(1L)
                var iso = baseIso
                var note: String? = null

                var ceiling = exposureCeiling
                if (expRange != null) ceiling = minOf(ceiling, expRange.upper)
                val floor = expRange?.lower ?: 1L

                val bounded = exposure.coerceIn(floor, maxOf(floor, ceiling))
                if (bounded != exposure) {
                    clampedExposure = true
                    // Spend what the shutter cannot take on ISO, so the exposure
                    // value is still reached even though the design's preference
                    // for constant noise had to give.
                    val residual = exposure.toDouble() / bounded
                    exposure = bounded
                    iso = (baseIso * residual).roundToInt()
                    note =
                        "exposure clamped to ${bounded / 1e6} ms; " +
                            String.format(Locale.US, "%.2f", ln(residual) / ln(2.0)) +
                            " EV moved to ISO, so this frame's noise differs from the others'"
                }
                if (isoRange != null) {
                    val boundedIso = iso.coerceIn(isoRange.lower, isoRange.upper)
                    if (boundedIso != iso) {
                        clampedIso = true
                        iso = boundedIso
                        note =
                            (note?.plus("; ") ?: "") +
                                "ISO also clamped — the requested EV separation was NOT achieved"
                    }
                }

                val steps =
                    (ev / aeStep).roundToInt().let {
                        if (aeRange != null) it.coerceIn(aeRange.lower, aeRange.upper) else it
                    }
                Shot(ev, exposure, iso, steps, note)
            }

        if (clampedIso) {
            notes.add(
                "ISO clamped as well as exposure, so this bracket spans less than the requested " +
                    "range and the fused frame will have less dynamic range than the plan assumes"
            )
        }
        return BracketPlan(shots, clampedExposure, clampedIso, baseExposure.toDouble() * baseIso)
    }

    /** Collects the frames of one burst, matched to requests by sensor timestamp. */
    private inner class BurstCollector(val expected: Int, val mapper: TimestampMapper) {
        private val imageLatch = CountDownLatch(expected)
        private val metadataLatch = CountDownLatch(expected)
        private val startedTimestamps = mutableListOf<Long>()
        private val payloads = arrayOfNulls<ByteArray>(expected)
        /**
         * The dimensions the HAL actually delivered, per frame.
         *
         * Carried because the deferred-encode path used to re-encode NV21 using
         * the session's *configured* `captureSize`, so a HAL that handed back a
         * differently sized buffer produced a sheared JPEG rather than an error —
         * and the intrinsics would then describe neither.
         */
        private val sizes = arrayOfNulls<android.util.Size>(expected)
        private val results = arrayOfNulls<TotalCaptureResult>(expected)
        private val timestamps = LongArray(expected)

        @Volatile var lastImageAtNs = 0L
        @Volatile var receivedCount = 0

        private var arrivalIndex = 0

        fun onStarted(sensorTimestampNs: Long) {
            synchronized(this) {
                if (startedTimestamps.size < expected) startedTimestamps.add(sensorTimestampNs)
            }
        }

        fun onCompleted(result: TotalCaptureResult) {
            val ts = result.get(CaptureResult.SENSOR_TIMESTAMP)
            synchronized(this) {
                val index = indexFor(ts)
                if (index in 0 until expected) results[index] = result
            }
            metadataLatch.countDown()
        }

        fun onFailed(reason: String) {
            onAsyncError("burst_frame_failed", reason)
            imageLatch.countDown()
            metadataLatch.countDown()
        }

        /**
         * Matches a delivered image to its request by sensor timestamp, which is
         * the only reliable key: `ImageReader` delivery order is not contractual
         * and a reordered bracket would silently mislabel every EV bias.
         */
        private fun indexFor(sensorTimestampNs: Long?): Int {
            if (sensorTimestampNs != null) {
                val i = startedTimestamps.indexOf(sensorTimestampNs)
                if (i >= 0) return i
            }
            return arrivalIndex
        }

        fun accept(image: android.media.Image) {
            val now = SystemClock.elapsedRealtimeNanos()
            synchronized(this) {
                val index = indexFor(image.timestamp)
                if (index in 0 until expected && payloads[index] == null) {
                    payloads[index] =
                        if (captureFormat == ImageFormat.JPEG) {
                            ImageUtils.jpegBytes(image)
                        } else {
                            ImageUtils.yuv420ToNv21(image)
                        }
                    sizes[index] = android.util.Size(image.width, image.height)
                    timestamps[index] = mapper.toMotionClockUs(image.timestamp)
                    receivedCount++
                }
                arrivalIndex++
                lastImageAtNs = now
            }
            imageLatch.countDown()
        }

        fun awaitImages(timeoutMs: Long) = imageLatch.await(timeoutMs, TimeUnit.MILLISECONDS)

        fun awaitMetadata(timeoutMs: Long) = metadataLatch.await(timeoutMs, TimeUnit.MILLISECONDS)

        fun payload(index: Int) = payloads.getOrNull(index)

        fun deliveredSize(index: Int) = sizes.getOrNull(index)

        fun result(index: Int) = results.getOrNull(index)

        fun timestampUs(index: Int) = timestamps.getOrElse(index) { 0L }

        /**
         * Shutter-to-shutter from `SENSOR_TIMESTAMP`: what the sensor can
         * sustain, separated from what the encoder then costs. That distinction
         * is what the JPEG-versus-YUV decision turns on (R3 §9).
         */
        fun shutterToShutterMs(): List<Double> =
            synchronized(this) {
                startedTimestamps.zipWithNext { a, b -> (b - a) / 1e6 }
            }
    }

    /**
     * Images must be closed or capture stalls after a few frames (§7 pitfall 4).
     * With 87 frames per session that failure arrives quickly and looks like a
     * hardware fault, so the close is in a `finally` and the reader is drained
     * even when no burst is collecting.
     */
    private fun drainCaptureReader(reader: ImageReader) {
        while (true) {
            val image = runCatching { reader.acquireNextImage() }.getOrNull() ?: return
            try {
                burst?.accept(image)
            } finally {
                image.close()
            }
        }
    }

    // ------------------------------------------------------------ misc --

    private fun hasUsableAeCompensation(c: CameraCharacteristics): Boolean {
        val range = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE) ?: return false
        val step =
            c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)
                ?.let { it.numerator.toDouble() / it.denominator } ?: return false
        // Two stops either side is the smallest span the default bracket needs.
        return range.lower * step <= -2.0 && range.upper * step >= 2.0
    }

    fun sampleClockOffset(): ClockOffsetSample =
        mapper?.sample()
            ?: ClockOffsetSample(
                cameraClockUs = System.nanoTime() / 1000,
                motionClockUs = SystemClock.elapsedRealtimeNanos() / 1000,
                offsetUs = 0,
                uncertaintyUs = 0,
            )

    fun close() {
        burst = null
        lock = null
        runCatching { session?.stopRepeating() }
        runCatching { session?.close() }
        session = null
        runCatching { device?.close() }
        device = null
        runCatching { captureReader?.close() }
        captureReader = null
        // Not released here: with `SurfaceProducer` the surface belongs to the
        // producer, and releasing one the engine still holds crashes on some
        // drivers. `previewProducer.release()` below is what frees it.
        previewSurface = null
        // Released on the platform thread for the same reason it was created
        // there: the entry belongs to Flutter's registry, which unregisters the
        // texture and touches the listener installed above.
        runCatching { previewProducer?.let { p -> onMainThread { p.release() } } }
        previewProducer = null
        characteristics = null
        mapper = null
    }

    fun dispose() {
        close()
        thread.quitSafely()
    }

    // -------------------------------------------------- camera plumbing --

    private fun openDevice(cameraId: String): CameraDevice {
        val latch = CountDownLatch(1)
        var opened: CameraDevice? = null
        var error: String? = null
        manager.openCamera(
            cameraId,
            object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    opened = camera
                    latch.countDown()
                }

                override fun onDisconnected(camera: CameraDevice) {
                    error = "the camera was disconnected while opening"
                    camera.close()
                    latch.countDown()
                    onAsyncError("camera_disconnected", "the camera was taken by another app")
                }

                override fun onError(camera: CameraDevice, err: Int) {
                    error = "openCamera reported error $err"
                    camera.close()
                    latch.countDown()
                }
            },
            handler,
        )
        if (!latch.await(OPEN_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            throw FlutterError("open_timeout", "opening camera $cameraId timed out", null)
        }
        return opened ?: throw FlutterError("open_failed", error ?: "openCamera failed", null)
    }

    private fun createSession(device: CameraDevice, surfaces: List<Surface>): CameraCaptureSession {
        val latch = CountDownLatch(1)
        var created: CameraCaptureSession? = null
        var failed = false
        val callback =
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(s: CameraCaptureSession) {
                    created = s
                    latch.countDown()
                }

                override fun onConfigureFailed(s: CameraCaptureSession) {
                    failed = true
                    latch.countDown()
                }
            }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            device.createCaptureSession(
                SessionConfiguration(
                    SessionConfiguration.SESSION_REGULAR,
                    surfaces.map { OutputConfiguration(it) },
                    executor,
                    callback,
                )
            )
        } else {
            @Suppress("DEPRECATION")
            device.createCaptureSession(surfaces, callback, handler)
        }
        if (!latch.await(SESSION_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            throw FlutterError("session_timeout", "configuring the capture session timed out", null)
        }
        if (failed) throw FlutterError("session_failed", "the capture session could not be configured", null)
        return created!!
    }
}

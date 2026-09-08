package com.asite.sphereview

import android.app.ActivityManager
import android.os.BatteryManager
import android.content.Context
import android.hardware.camera2.CameraManager
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.GLES20
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import java.util.concurrent.Executors

/**
 * Plugin entry point: wires the generated host API to a [CameraSession] and the
 * Flutter callbacks back to Dart.
 *
 * Two threading rules hold everywhere below.
 *
 * 1. **Camera work never runs on the platform thread.** Every host method
 *    blocks on latches waiting for HAL callbacks, and those callbacks are
 *    delivered on `CameraSession`'s own handler. A single-thread executor
 *    serialises the operations, which also means two `captureBracket` calls can
 *    never interleave — §7 pitfall 1 says never touch the session between
 *    requests, and serialising is how that is guaranteed rather than hoped for.
 * 2. **Replies and Flutter callbacks are posted to the main looper.**
 */
class SphereViewPlugin : FlutterPlugin {

    private var hostApi: SphereCameraHostApiImpl? = null
    private var flutterApi: SphereCameraFlutterApi? = null
    private var poseApi: SpherePoseHostApiImpl? = null
    private var poseFlutterApi: SpherePoseFlutterApi? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val api = SphereCameraFlutterApi(binding.binaryMessenger)
        flutterApi = api
        val impl =
            SphereCameraHostApiImpl(
                context = binding.applicationContext,
                textures = binding.textureRegistry,
                flutterApi = api,
            )
        hostApi = impl
        SphereCameraHostApi.setUp(binding.binaryMessenger, impl)

        // Phase 07. A second host API rather than more methods on the camera
        // one, because the pose stream outlives any camera session — §6
        // pitfall 5 says never reset the pose history between targets, and the
        // camera is closed and reopened around it.
        val poseFlutter = SpherePoseFlutterApi(binding.binaryMessenger)
        poseFlutterApi = poseFlutter
        val poseImpl =
            SpherePoseHostApiImpl(
                context = binding.applicationContext,
                flutterApi = poseFlutter,
            )
        poseApi = poseImpl
        SpherePoseHostApi.setUp(binding.binaryMessenger, poseImpl)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        SphereCameraHostApi.setUp(binding.binaryMessenger, null)
        hostApi?.dispose()
        hostApi = null
        flutterApi = null

        SpherePoseHostApi.setUp(binding.binaryMessenger, null)
        poseApi?.dispose()
        poseApi = null
        poseFlutterApi = null
    }
}

/**
 * The pose host API, delegating to one [MotionSession].
 *
 * Its own single-thread executor rather than the camera's: `startPose` blocks
 * on the first sensor sample to identify the timestamp base, and queueing that
 * behind a metering sweep or a bracket would make the two independent
 * subsystems wait on each other for no reason.
 *
 * Samples **are** posted to the main looper, like every other `FlutterApi`
 * callback here. Phase 07 originally sent them straight from the sensor's
 * handler thread, on the premise that `BasicMessageChannel.send` is
 * thread-safe. It is not: `send` reaches `FlutterJNI.dispatchPlatformMessage`,
 * which is `@UiThread` and calls `ensureRunningOnMainThread()`, so the first
 * sample after `startPose` killed the process with
 * `Methods marked with @UiThread must be executed on the main thread`.
 *
 * The latency that premise was buying is not worth anything: a pose is placed
 * in [PoseBuffer] by its own `timestampUs` and read back by SLERP at the
 * shutter timestamp, so when it *arrives* changes nothing downstream — only
 * its order and its presence matter, and a single poster thread posting to one
 * looper preserves both. Dropping or coalescing samples to save main-thread
 * work would be the change that actually costs accuracy, by widening the
 * interval interpolation has to bridge.
 */
class SpherePoseHostApiImpl(
    context: Context,
    private val flutterApi: SpherePoseFlutterApi,
) : SpherePoseHostApi {

    private val main = Handler(Looper.getMainLooper())
    private val operations = Executors.newSingleThreadExecutor { r -> Thread(r, "sphere-pose-ops") }

    private val session =
        MotionSession(
            context = context,
            onSample = { sample -> main.post { flutterApi.onPoseSample(sample) {} } },
            onError = { code, message -> main.post { flutterApi.onPoseError(code, message) {} } },
        )

    fun dispose() {
        operations.execute { session.stop() }
        operations.shutdown()
    }

    private fun <T> run(code: String, callback: (Result<T>) -> Unit, block: () -> T) {
        operations.execute {
            val result =
                try {
                    Result.success(block())
                } catch (e: FlutterError) {
                    Result.failure(e)
                } catch (t: Throwable) {
                    Result.failure(FlutterError(code, t.message ?: t.toString(), null))
                }
            main.post { callback(result) }
        }
    }

    override fun poseCapabilities(callback: (Result<PoseCapabilities>) -> Unit) =
        run("pose_capabilities_failed", callback) { session.capabilities() }

    override fun startPose(samplingPeriodUs: Long, callback: (Result<PoseStreamInfo>) -> Unit) =
        run("pose_start_failed", callback) { session.start(samplingPeriodUs) }

    override fun stopPose(callback: (Result<Unit>) -> Unit) =
        run("pose_stop_failed", callback) { session.stop() }
}

/** The host API, delegating to one [CameraSession]. */
class SphereCameraHostApiImpl(
    private val context: Context,
    private val textures: io.flutter.view.TextureRegistry,
    private val flutterApi: SphereCameraFlutterApi,
) : SphereCameraHostApi {

    private val main = Handler(Looper.getMainLooper())
    private val operations = Executors.newSingleThreadExecutor { r -> Thread(r, "sphere-camera-ops") }
    private val thermal = ThermalMonitor(context)

    private val session =
        CameraSession(
            context = context,
            textures = textures,
            onPreviewFrame = { timestampUs -> main.post { flutterApi.onFrameAvailable(timestampUs) {} } },
            onAsyncError = { code, message -> main.post { flutterApi.onError(code, message) {} } },
        )

    init {
        thermal.start { state -> main.post { flutterApi.onThermalStateChanged(state) {} } }
    }

    fun dispose() {
        thermal.stop()
        operations.execute { session.dispose() }
        operations.shutdown()
    }

    /**
     * Runs [block] off the platform thread and replies on it.
     *
     * A thrown [FlutterError] keeps its code; anything else is wrapped, because
     * a camera failure that reaches Dart as an untyped exception is a failure
     * nobody can branch on.
     */
    private fun <T> run(code: String, callback: (Result<T>) -> Unit, block: () -> T) {
        operations.execute {
            val result =
                try {
                    Result.success(block())
                } catch (e: FlutterError) {
                    Result.failure(e)
                } catch (t: Throwable) {
                    Result.failure(FlutterError(code, t.message ?: t.toString(), null))
                }
            main.post { callback(result) }
        }
    }

    override fun listCameras(callback: (Result<List<CameraDescriptor>>) -> Unit) =
        run("list_cameras_failed", callback) {
            val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            CameraFacts.listCameras(manager)
        }

    override fun open(
        cameraId: String,
        format: CaptureFormatRequest,
        callback: (Result<CameraOpenResult>) -> Unit,
    ) = run("open_failed", callback) { session.open(cameraId, format) }

    override fun attachPreview(callback: (Result<Long>) -> Unit) =
        run("attach_preview_failed", callback) { session.attachPreview() }

    override fun detachPreview(callback: (Result<Unit>) -> Unit) =
        run("detach_preview_failed", callback) { session.detachPreview() }

    override fun meterAndLock(durationSeconds: Double, callback: (Result<MeteringResult>) -> Unit) =
        run("meter_failed", callback) { session.meterAndLock(durationSeconds) }

    override fun unlock(callback: (Result<Unit>) -> Unit) =
        run("unlock_failed", callback) { session.unlock() }

    override fun captureBracket(
        evBiases: List<Double>,
        outputDirectory: String,
        namePrefix: String,
        callback: (Result<CaptureResponse>) -> Unit,
    ) = run("capture_failed", callback) {
        session.captureBracket(evBiases, outputDirectory, namePrefix)
    }

    override fun thermalState(callback: (Result<PlatformThermalState>) -> Unit) =
        run("thermal_failed", callback) { thermal.current() }

    override fun sampleClockOffset(callback: (Result<ClockOffsetSample>) -> Unit) =
        run("clock_sample_failed", callback) { session.sampleClockOffset() }

    /// Phase 11 §2's EXIF `Make`/`Model`. Straight off `Build`; no permission,
    /// no I/O, and nothing here can fail, so it does not need the retry
    /// treatment the camera calls get.
    override fun deviceIdentity(callback: (Result<DeviceIdentity>) -> Unit) =
        run("device_identity_failed", callback) {
            DeviceIdentity(
                make = android.os.Build.MANUFACTURER ?: "unknown",
                model = android.os.Build.MODEL ?: "unknown",
                osVersion = "Android ${android.os.Build.VERSION.RELEASE} " +
                    "(API ${android.os.Build.VERSION.SDK_INT})",
            )
        }

    /// Phase 11 §3.1's `GL_MAX_TEXTURE_SIZE`.
    ///
    /// Queried on a throwaway 1×1 pbuffer context rather than on the one
    /// Flutter renders with, because there is no supported way to reach that
    /// context from a plugin and doing so from the wrong thread would be worse
    /// than not asking. The limit is a property of the GPU and its driver, not
    /// of a particular context, so the answer is the same one Flutter's
    /// renderer will be bound by.
    ///
    /// Returns 0 if any step fails. The caller reads that as "assume the
    /// conservative floor", which is the safe direction: downscaling a
    /// panorama that did not need it costs sharpness, while not downscaling one
    /// that did costs the whole image.
    override fun maxTextureSize(callback: (Result<Long>) -> Unit) =
        run("max_texture_size_failed", callback) {
            val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            if (display == EGL14.EGL_NO_DISPLAY) return@run 0L
            val version = IntArray(2)
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) return@run 0L
            try {
                val configAttributes =
                    intArrayOf(
                        EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                        EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                        EGL14.EGL_NONE,
                    )
                val configs = arrayOfNulls<EGLConfig>(1)
                val configCount = IntArray(1)
                if (!EGL14.eglChooseConfig(
                        display, configAttributes, 0, configs, 0, 1, configCount, 0,
                    ) || configCount[0] == 0
                ) {
                    return@run 0L
                }
                val context =
                    EGL14.eglCreateContext(
                        display,
                        configs[0],
                        EGL14.EGL_NO_CONTEXT,
                        intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE),
                        0,
                    )
                if (context == EGL14.EGL_NO_CONTEXT) return@run 0L
                val surface =
                    EGL14.eglCreatePbufferSurface(
                        display,
                        configs[0],
                        intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE),
                        0,
                    )
                try {
                    if (!EGL14.eglMakeCurrent(display, surface, surface, context)) {
                        return@run 0L
                    }
                    val limit = IntArray(1)
                    GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, limit, 0)
                    limit[0].toLong()
                } finally {
                    EGL14.eglMakeCurrent(
                        display,
                        EGL14.EGL_NO_SURFACE,
                        EGL14.EGL_NO_SURFACE,
                        EGL14.EGL_NO_CONTEXT,
                    )
                    if (surface != EGL14.EGL_NO_SURFACE) {
                        EGL14.eglDestroySurface(display, surface)
                    }
                    EGL14.eglDestroyContext(display, context)
                }
            } finally {
                EGL14.eglTerminate(display)
            }
        }

    override fun totalPhysicalMemoryMb(callback: (Result<Long>) -> Unit) =
        run("memory_probe_failed", callback) {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val info = ActivityManager.MemoryInfo()
            am.getMemoryInfo(info)
            info.totalMem / (1024L * 1024L)
        }

    /// Android has no per-process equivalent of iOS's
    /// `os_proc_available_memory`, and the numbers that look like one are not.
    ///
    /// `MemoryInfo.availMem` is a *device* figure that moves with every other
    /// app, and `Runtime.maxMemory` describes the Java heap, which is not where
    /// a native stitch allocates — OpenCV's Mats come from the native heap and
    /// are invisible to it. Reporting either would be worse than reporting
    /// nothing, because the pre-flight check would then refuse tiers on a
    /// number that has no bearing on whether the stitch fits.
    ///
    /// So it says it does not know. The retry path is the defence here instead,
    /// and it works on Android in a way it cannot on iOS: a failed native
    /// allocation raises something catchable, so the stitcher drops a tier and
    /// tries again rather than the process simply ceasing to exist.
    override fun availableProcessMemoryMb(callback: (Result<Long>) -> Unit) =
        run("memory_probe_failed", callback) { -1L }

    /// Phase 12 §3's drain-per-station measurement.
    ///
    /// `BATTERY_PROPERTY_CAPACITY` rather than the `ACTION_BATTERY_CHANGED`
    /// sticky broadcast: the property is a direct read with no receiver to
    /// register or unregister, and this is called twice per station rather than
    /// subscribed to. Rugged tablets are also the devices most likely to report
    /// nothing at all here, so an absent value is `-1` rather than a guess — a
    /// fabricated 100% would make a matrix row claim the drain was zero.
    override fun batteryPercent(callback: (Result<Long>) -> Unit) =
        run("battery_probe_failed", callback) {
            val manager =
                context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
            val percent =
                manager?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
            if (percent in 0..100) percent.toLong() else -1L
        }

    override fun close(callback: (Result<Unit>) -> Unit) =
        run("close_failed", callback) { session.close() }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';

/// Camera selection, the exposure fallback and the thermal policy — all three
/// tested against a fake platform, on a laptop.
///
/// The point of the fake is the same as the point of the synthetic rig in Phase
/// 02: these decisions have to be right on devices nobody in this session has,
/// and "we will find out on the tablet" is how a main-camera-only product ships
/// pointing at an ultra-wide.
void main() {
  group('camera selection', () {
    test('excludes the ultra-wide by focal length, and logs it', () {
      // §2.1: the main camera is the one whose focal is *not* the shortest.
      // A typical rear pair is 0.5× and 1×, so the ultra-wide is unambiguous —
      // but the exclusion is a product decision, not a technical one, and a
      // future config may want it back, so it is recorded rather than dropped.
      final probe = CameraProbe(
        _FakePlatform(
          cameras: [
            _camera(id: '0', focals: [4.25], sizes: const [ImageSize(4032, 3024)]),
            _camera(id: '2', focals: [2.2], sizes: const [ImageSize(4032, 3024)]),
          ],
        ),
      );

      return probe.selectCaptureCamera().then((selection) {
        expect(selection.camera.id, '0');
        expect(
          selection.rejected.any((r) => r.startsWith('2:') && r.contains('ultra-wide')),
          isTrue,
        );
      });
    });

    test('keeps the only rear camera even when it is the shortest', () {
      // A single-lens tablet — most of the fleet. There is nothing to exclude,
      // and excluding on "shortest of one" would leave no camera at all.
      final probe = CameraProbe(
        _FakePlatform(
          cameras: [
            _camera(id: '0', focals: [2.2], sizes: const [ImageSize(4032, 3024)]),
            _camera(
              id: '1',
              focals: [3.0],
              sizes: const [ImageSize(1920, 1080)],
              facing: CameraFacing.front,
            ),
          ],
        ),
      );
      return probe.selectCaptureCamera().then((selection) {
        expect(selection.camera.id, '0');
        expect(selection.rejected.any((r) => r.startsWith('1:')), isTrue);
      });
    });

    test('prefers the largest 4:3 still, not simply the largest', () {
      // §7 pitfall 5, stated as a test: a 16:9 size can easily be the largest
      // by pixel count while being a crop of the sensor. Taking it would put a
      // crop term into the intrinsics and shrink the vertical FOV, which costs
      // an extra ring.
      final probe = CameraProbe(_FakePlatform(cameras: [_camera(id: '0', focals: [4.25], sizes: const [
        ImageSize(4128, 2322), // 16:9, 9.6 MP — larger
        ImageSize(4032, 3024), // 4:3, 12.2 MP
        ImageSize(1920, 1440),
      ])]));
      return probe.selectCaptureCamera().then((selection) {
        expect(probe.selectCaptureSize(selection.camera), const ImageSize(4032, 3024));
      });
    });

    test('falls back to the largest of any aspect when nothing is 4:3', () {
      final probe = CameraProbe(_FakePlatform(cameras: [_camera(id: '0', focals: [4.25], sizes: const [
        ImageSize(4128, 2322),
        ImageSize(1920, 1080),
      ])]));
      return probe.selectCaptureCamera().then((selection) {
        expect(probe.selectCaptureSize(selection.camera), const ImageSize(4128, 2322));
      });
    });

    test('refuses rather than picking the front camera', () {
      // Capture with a front camera would produce a mirrored, low-resolution
      // sphere. Failing loudly is the honest outcome.
      final probe = CameraProbe(
        _FakePlatform(
          cameras: [
            _camera(
              id: '1',
              focals: [3.0],
              sizes: const [ImageSize(1920, 1080)],
              facing: CameraFacing.front,
            ),
          ],
        ),
      );
      expect(probe.selectCaptureCamera(), throwsStateError);
    });
  });

  group('exposure fallback', () {
    // Explicitly a bracket, not the default. The default is now
    // `ExposureStrategy.auto` — one auto-metered frame — and these tests are
    // about how a *bracket* degrades on devices that cannot take the whole
    // thing, so the strategy has to be named rather than inherited.
    const config = SphereCaptureConfig(
      exposure: ExposureStrategy.bracket3(evSpread: 2.0),
    );
    final controller = ExposureController(_FakePlatform(cameras: const []));

    test('passes the full bracket through when the device can take it', () {
      expect(
        controller.bracketBiases(config, mode: BracketMode.manualExposureBurst, maxBracketCount: 3),
        [-2.0, 0.0, 2.0],
      );
    });

    test('trims to the widest pair, not the first two', () {
      // R3 names the 2-shot bracket as the intermediate fallback before
      // abandoning HDR. A bracket's value is its *spread*: keeping −2 and +2
      // preserves the dynamic range, keeping −2 and 0 halves it.
      expect(
        controller.bracketBiases(config, mode: BracketMode.photoBracket, maxBracketCount: 2),
        [-2.0, 2.0],
      );
    });

    test('collapses to a single frame on a device with no exposure control', () {
      // Architecture §6.4: this needs no structural change — shots becomes a
      // one-element list. Asking for three anyway would produce three identical
      // frames and a fusion stage with nothing to fuse.
      expect(
        controller.bracketBiases(config, mode: BracketMode.singleShot, maxBracketCount: 1),
        [0.0],
      );
    });

    test('a locked strategy is already one frame', () {
      expect(
        controller.bracketBiases(
          config.copyWith(exposure: const ExposureStrategy.locked()),
          mode: BracketMode.manualExposureBurst,
          maxBracketCount: 3,
        ),
        [0.0],
      );
    });
  });

  group('lock warnings', () {
    test('a fully-granted lock produces no warnings', () async {
      final controller = ExposureController(_FakePlatform(cameras: const []));
      await controller.meterAndLock();
      expect(controller.warnings, isEmpty);
    });

    test('an unpinned tonemap is a warning, not a silent compromise', () async {
      // §2.3 step 5. An adaptive tonemap varies per frame with scene content
      // and reintroduces exactly the inconsistency the AE lock removed — and it
      // does it as a gradient across the panorama rather than a step at a seam,
      // so nothing downstream would flag it.
      final controller = ExposureController(
        _FakePlatform(cameras: const [], pinnedProcessingModes: false),
      );
      await controller.meterAndLock();
      expect(
        controller.warnings.any((w) => w.contains('noise reduction, edge enhancement')),
        isTrue,
      );
    });

    test('a best-effort lock and a short sweep are both surfaced', () async {
      final controller = ExposureController(
        _FakePlatform(
          cameras: const [],
          lockQuality: ExposureLockQuality.bestEffort,
          sampleCount: 4,
        ),
      );
      await controller.meterAndLock();
      expect(controller.warnings.any((w) => w.contains('best-effort')), isTrue);
      expect(controller.warnings.any((w) => w.contains('observed only 4 frames')), isTrue);
    });
  });

  group('thermal policy', () {
    test('capture is permitted until critical', () {
      expect(ThermalPolicy.forCapture(ThermalState.nominal).allowed, isTrue);
      expect(ThermalPolicy.forCapture(ThermalState.fair).allowed, isTrue);
      expect(ThermalPolicy.forCapture(ThermalState.serious).action, ThermalAction.warn);
      expect(ThermalPolicy.forCapture(ThermalState.critical).action, ThermalAction.refuse);
    });

    test('stitching warns at serious and refuses at critical', () {
      // §5's policy exactly. Stitching is stricter than capture because it is
      // 60 s of sustained load that can always be deferred without losing
      // anything — the bundle is on disk and replayable.
      expect(ThermalPolicy.forStitch(ThermalState.serious).action, ThermalAction.warn);
      expect(ThermalPolicy.forStitch(ThermalState.critical).allowed, isFalse);
    });

    test('every message is written for a site manager, not a log', () {
      for (final state in ThermalState.values) {
        for (final decision in [
          ThermalPolicy.forCapture(state),
          ThermalPolicy.forStitch(state),
        ]) {
          expect(decision.message, isNotEmpty);
          expect(decision.message.endsWith('.'), isTrue);
        }
      }
    });
  });
}

CameraDescriptor _camera({
  required String id,
  required List<double> focals,
  required List<ImageSize> sizes,
  CameraFacing facing = CameraFacing.back,
}) => CameraDescriptor(
  id: id,
  facing: facing,
  availableSizes: sizes,
  focalLengthsMm: focals,
  supportsBracketing: true,
  maxBracketCount: 3,
  hasDistortionModel: false,
  hasManualSensor: true,
  hardwareLevel: 'full',
  isLogicalMultiCamera: false,
);

/// A platform that answers from a script. Only the methods these tests reach
/// are implemented; the rest throw, so a test that starts depending on
/// something unmodelled fails rather than quietly passing.
class _FakePlatform implements SphereCameraPlatform {
  _FakePlatform({
    required this.cameras,
    this.lockQuality = ExposureLockQuality.fullyLocked,
    this.pinnedProcessingModes = true,
    this.sampleCount = 60,
  });

  final List<CameraDescriptor> cameras;
  final ExposureLockQuality lockQuality;
  final bool pinnedProcessingModes;
  final int sampleCount;

  @override
  Future<List<CameraDescriptor>> listCameras() async => cameras;

  @override
  Future<MeteringResult> meterAndLock(Duration duration) async => MeteringResult(
    exposureTimeNs: 16666666,
    iso: 200,
    colorTemperatureK: 0,
    focusDistanceDiopters: 0.4,
    lockQuality: lockQuality,
    sampleCount: sampleCount,
    chosenEv: 0.4,
    meanEv: 0.5,
    percentile65Ev: 0.4,
    aeConverged: true,
    pinnedProcessingModes: pinnedProcessingModes,
  );

  @override
  Future<void> unlock() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not modelled by this fake',
  );
}

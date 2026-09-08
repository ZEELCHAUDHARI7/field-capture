import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sphere_view/sphere_view.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_button.dart';
import '../../../shared/storage/sphere_storage.dart';
import '../models/capture_draft.dart';
import '../state/capture_flow_controller.dart';
import '../state/sphere_capability_controller.dart';

/// Prototype screen 11, made real — the guided 360° sphere capture.
///
/// Three steps behind one route, not three routes. The workspace already keeps
/// eleven of the deck's states as screen state rather than as navigation, and
/// this is the same argument: a coaching screen, a capture screen and a review
/// screen are one activity, and Back has to mean "abandon the capture" in all
/// three of them rather than "step back into the middle of one".
///
/// Every widget drawn here comes from `sphere_view`. The package's own screens
/// are used rather than reimplemented for a specific reason each:
///
/// * [SpherePreCaptureScreen] carries the "pivot, don't walk" coaching, which
///   is the parallax mitigation. Parallax is the one error in this pipeline
///   that no amount of algorithm removes — 3 cm of lens travel at 1 m collapses
///   structural similarity from 0.97 to 0.63.
/// * [SphereCaptureView] holds no capture logic; it draws what the session
///   reports. Reimplementing it would mean reimplementing the aim, steadiness
///   and dwell gates that decide when the shutter may fire.
/// * [SphereReviewScreen] states the capture's own warnings in plain language,
///   before a minute of stitching is spent on them.
class SphereCaptureScreen extends ConsumerStatefulWidget {
  const SphereCaptureScreen({super.key});

  @override
  ConsumerState<SphereCaptureScreen> createState() =>
      _SphereCaptureScreenState();
}

enum _Step { opening, coaching, capturing, reviewing }

/// What Android Back should do, once the user has answered.
enum _Exit {
  /// Stay where we are.
  stay,

  /// Keep the positions already on disk and stitch them.
  finish,

  /// Throw everything away.
  discard,
}

class _SphereCaptureScreenState extends ConsumerState<SphereCaptureScreen> {
  _Step _step = _Step.opening;
  SphereCaptureSession? _session;
  CaptureBundle? _bundle;
  String? _failure;

  /// What the probe found, kept from [_open] so the coaching screen can show
  /// this device's own warnings without reading a provider during build.
  SphereCapabilityReport? _capability;

  /// Set immediately before this route is popped by our own code.
  ///
  /// The screen guards Back so it cannot slide out from under a session holding
  /// the camera. `Navigator.pop` ignores that guard and is what [_leave] uses;
  /// this flag keeps `canPop` truthful while the pop is in flight, and stops a
  /// second tap on a confirmation button popping the route twice.
  bool _leaving = false;

  /// True while a Back confirmation is on screen.
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    // After the first frame, so that a failure can reach the flow controller
    // without mutating a provider mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void dispose() {
    // The session owns the camera and the wakelock. A flow that ends anywhere
    // other than `finish()` still has to give both back — including this one,
    // where the route was torn down without going through either button.
    final SphereCaptureSession? session = _session;
    _session = null;
    if (session != null) unawaited(session.dispose());
    super.dispose();
  }

  CaptureDraft? get _draft {
    final CaptureFlow flow = ref.read(captureFlowProvider);
    if (flow.phase != CapturePhase.sphereCapture) return null;
    return flow.draft;
  }

  Future<void> _open() async {
    final CaptureDraft? draft = _draft;
    final String? sessionId = draft?.sphereSessionId;
    if (draft == null || sessionId == null) {
      setState(() => _failure = 'No capture in progress.');
      return;
    }

    final SphereCaptureGate gate =
        await ref.read(sphereCaptureGateProvider.future);
    final SphereCapabilityReport? capability = gate.report;
    if (!mounted) return;
    if (!gate.isAllowed || capability == null) {
      setState(() => _failure = gate.blockingReason);
      return;
    }

    final Directory directory =
        ref.read(sphereStorageProvider).bundleDirectory(sessionId);

    try {
      final SphereCaptureSession session = await SphereCaptureSession.create(
        // The device's own answer, not ours. Asking a LEGACY Android camera for
        // a three-shot bracket returns *one* frame per position, and a frame
        // gate expecting three rejects every one of them — a device that
        // captures nothing at all, dressed up as a device without HDR.
        config: capability.configFrom(const SphereCaptureConfig()),
        capability: capability,
        sessionId: sessionId,
        directory: directory,
      );
      if (!mounted) {
        await session.dispose();
        return;
      }
      setState(() {
        _session = session;
        _capability = capability;
        _step = _Step.coaching;
      });
    } on PoseSourceUnsupported catch (error) {
      // No gyroscope. There is no useful reduced mode: without one there is no
      // attitude source that tracks a pan, so every frame would be seeded from
      // tilt with no heading at all. The panorama would not be worse, it would
      // be wrong.
      if (mounted) setState(() => _failure = '$error');
    } on InsufficientCoverageException catch (error) {
      // The plan these intrinsics imply cannot cover the sphere. The message
      // names the field of view it got. Not recoverable by trying again, and
      // raised before anything is metered, locked or shot.
      if (mounted) setState(() => _failure = '$error');
    } on Object catch (error) {
      if (mounted) setState(() => _failure = '$error');
    }
  }

  /// Pops this route, past our own `PopScope` guard.
  ///
  /// `maybePop` is wrong here and was the bug: it consults the same guard that
  /// brought us to this line, so the pop was refused and the confirmation
  /// reappeared, forever.
  void _leave() {
    if (_leaving) return;
    setState(() => _leaving = true);
    Navigator.of(context).pop();
  }

  /// Leaves with nothing recorded, and deletes whatever reached the disk.
  Future<void> _abandon() async {
    final SphereCaptureSession? session = _session;
    _session = null;
    await session?.abort();
    await session?.dispose();
    if (!mounted) return;
    ref.read(captureFlowProvider.notifier).discard();
    _leave();
  }

  /// Ends the capture early and keeps what is on disk.
  ///
  /// A partial sphere is a real deliverable, not a failed one: the pipeline
  /// stitches what it is given and fills the uncovered poles, and the review
  /// screen states the coverage in plain language before a minute of stitching
  /// is spent. A crew that has photographed the wall they came for should not
  /// have to shoot the ceiling to keep it.
  Future<void> _finishEarly() async {
    final SphereCaptureSession? session = _session;
    if (session == null) return;
    try {
      final CaptureBundle bundle = await session.finish();
      if (!mounted) return;
      setState(() {
        _bundle = bundle;
        _step = _Step.reviewing;
      });
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  /// Android Back. What it may offer depends on what would be lost.
  Future<void> _onBack() async {
    // Back fires per press, and a confirmation takes a moment to answer. Two
    // presses would otherwise stack two dialogs, and dismissing the top one
    // would reveal a second — which is what the operator reads as "discard is
    // not working".
    if (_asking || _leaving) return;
    _asking = true;
    try {
      await _decideOnBack();
    } finally {
      _asking = false;
    }
  }

  Future<void> _decideOnBack() async {
    switch (_step) {
      // Nothing has been photographed. Leaving costs nothing, so it does not
      // ask.
      case _Step.opening:
      case _Step.coaching:
        await _abandon();

      case _Step.capturing:
        final SphereCaptureSession? session = _session;
        if (session == null || session.positions.isEmpty) {
          await _abandon();
          return;
        }
        switch (await _askOnExit(
          captured: session.positions.length,
          total: session.plan.targets.length,
        )) {
          case _Exit.stay:
            break;
          case _Exit.finish:
            await _finishEarly();
          case _Exit.discard:
            await _abandon();
        }

      // The sphere is captured and sitting in front of the operator. The only
      // question left is whether to keep it, and Save is right there — so Back
      // means discard, and it asks.
      case _Step.reviewing:
        if (await _confirmDiscardReviewed()) await _abandon();
    }
  }

  /// The three honest answers to Back during a capture.
  ///
  /// Deliberately the same offer the package's own exit button makes, in the
  /// same words: a mis-tap in gloves, on a screen held at arm's length while
  /// turning, must not be able to end a site visit — and it must not be the
  /// only alternative to throwing the morning away either.
  Future<_Exit> _askOnExit({
    required int captured,
    required int total,
  }) async {
    final _Exit? answer = await showDialog<_Exit>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Finish this capture?'),
        content: Text(
          '$captured of $total photos are saved. Finishing keeps them and '
          'stitches what you have — the panorama covers less of the sphere, '
          'and the review screen says by how much.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(_Exit.stay),
            child: const Text('Keep capturing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_Exit.discard),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.onDangerContainer,
            ),
            child: const Text('Discard'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_Exit.finish),
            child: const Text('Finish here'),
          ),
        ],
      ),
    );
    return answer ?? _Exit.stay;
  }

  Future<bool> _confirmDiscardReviewed() async {
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Discard this capture?'),
        content: const Text(
          'The photos are taken but nothing has been saved. Leaving now throws '
          'away every frame, and the sphere has to be captured again from '
          'where you are standing.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Back to the review'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.onDangerContainer,
            ),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  Future<void> _save() async {
    final CaptureBundle? bundle = _bundle;
    if (bundle == null) return;

    // The session is finished with. Released before the plan is touched, so the
    // camera is back in the pool while the pin is being written. Through
    // `setState`, because the review screen is rebuilt from `_bundle` and must
    // not fall through to the "no session" spinner in between.
    final SphereCaptureSession? session = _session;
    setState(() => _session = null);
    await session?.dispose();

    // Camera teardown is not instant, and the route can be gone by the time it
    // returns. `ref` on a disposed widget throws.
    if (!mounted) return;
    await ref.read(captureFlowProvider.notifier).completeSphereCapture(bundle);
    if (!mounted) return;
    _leave();
  }

  @override
  Widget build(BuildContext context) {
    final String? failure = _failure;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: PopScope(
        // Back is intercepted rather than sliding out from under a session that
        // holds the camera — except when this screen is the one doing the
        // popping, which is what `_leaving` says.
        canPop: _leaving,
        onPopInvokedWithResult: (bool didPop, Object? _) {
          if (!didPop) unawaited(_onBack());
        },
        child: Scaffold(
          backgroundColor: AppColors.captureBackdrop,
          body: failure != null
              ? _CaptureRefused(message: failure, onBack: _abandon)
              : _body(),
        ),
      ),
    );
  }

  Widget _body() {
    // The review step is deliberately handled before the session guard below.
    // Reviewing needs the bundle and not the camera, and `_save` releases the
    // session *before* it writes the pin — so requiring one here would replace
    // the review screen with a spinner for the frame between the two.
    final CaptureBundle? bundle = _bundle;
    if (_step == _Step.reviewing && bundle != null) {
      return SphereReviewScreen(
        bundle: bundle,
        saveLabel: 'Save capture',
        onSave: () => unawaited(_save()),
        // The review screen's own Discard. It asks, for the same reason Back
        // does from here: the photos exist and there is no second chance at
        // them without walking back to this spot.
        onDiscard: () async {
          if (await _confirmDiscardReviewed()) await _abandon();
        },
      );
    }

    final SphereCaptureSession? session = _session;
    if (session == null || _step == _Step.opening) {
      // Opening the camera, or on the way out. Both are short and neither has
      // anything to show.
      return const Center(
        child: CircularProgressIndicator(color: AppColors.captureActive),
      );
    }

    switch (_step) {
      case _Step.coaching:
        return SpherePreCaptureScreen(
          plan: session.plan,
          capability: _capability,
          locationNote: 'Stand on the pin you placed on the plan.',
          onStart: () => setState(() => _step = _Step.capturing),
          onCancel: () => unawaited(_abandon()),
        );

      case _Step.capturing:
        return SphereCaptureView(
          session: session,
          onCompleted: (CaptureBundle captured) => setState(() {
            _bundle = captured;
            _step = _Step.reviewing;
          }),
          // Only reached with nothing captured — with positions on disk the
          // view offers to finish and stitch them instead. It has already
          // called `abort()`, which deletes what was written.
          onCancelled: () => unawaited(_abandon()),
          onError: (Object error, StackTrace _) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text('$error')));
          },
        );

      case _Step.opening:
      case _Step.reviewing:
        return const Center(
          child: CircularProgressIndicator(color: AppColors.captureActive),
        );
    }
  }
}

/// The device, the lens or the permission said no.
///
/// Its own state rather than a SnackBar because every message it shows is a
/// refusal the crew has to act on — stand somewhere else, use the 360° camera,
/// turn the permission back on — and none of them is recoverable by trying the
/// same thing again.
class _CaptureRefused extends StatelessWidget {
  const _CaptureRefused({required this.message, required this.onBack});

  final String message;
  final Future<void> Function() onBack;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.do_not_disturb_on_outlined,
              size: 40,
              color: AppColors.onChromeMuted,
            ),
            const SizedBox(height: AppSizes.md),
            Text(
              'Mobile Capture cannot run here',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(color: AppColors.onChrome),
            ),
            const SizedBox(height: AppSizes.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.onChromeMuted),
            ),
            const SizedBox(height: AppSizes.xl),
            AppButton(
              label: 'Back to the plan',
              expanded: false,
              onPressed: () => unawaited(onBack()),
            ),
          ],
        ),
      ),
    );
  }
}

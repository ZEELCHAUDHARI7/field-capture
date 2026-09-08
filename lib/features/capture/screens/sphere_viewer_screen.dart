import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sphere_view/sphere_view.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/field_app_bar.dart';
import '../../plan/models/plan_marker.dart';
import '../../plan/models/workspace_data.dart';
import '../../plan/state/workspace_controller.dart';

/// The captured sphere, on screen.
///
/// [SphereViewer] is a GPU fragment shader over the equirectangular JPEG rather
/// than a textured sphere mesh, which is why this route needs no 3D engine and
/// no new dependency (ASSUMPTIONS.md §I1 still holds).
///
/// The panorama is read from disk by path. Nothing is copied, decoded here or
/// held in memory by this screen — a 6144 px panorama decoded into a list tile
/// is how a tablet runs out of memory, and the viewer downscales to the GPU's
/// own texture limit and says so when it does.
class SphereViewerScreen extends ConsumerWidget {
  const SphereViewerScreen({
    super.key,
    required this.calibrationId,
    required this.captureId,
  });

  final String calibrationId;
  final String captureId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<LevelWorkspaceData> data =
        ref.watch(workspaceDataProvider(calibrationId));

    final CaptureMarker? marker = data.valueOrNull?.captures
        .where((CaptureMarker c) => c.id == captureId)
        .firstOrNull;

    final String? path = marker?.viewablePath;

    return Scaffold(
      backgroundColor: AppColors.captureBackdrop,
      appBar: FieldAppBar(
        title: marker?.name ?? '360° image',
        subtitle: marker == null ? null : Formatters.relative(marker.recordedAt),
      ),
      body: switch ((marker, path)) {
        (null, _) => const _ViewerNotice(
            title: 'This capture is no longer here',
            message: 'It was discarded, or the level was reloaded while the '
                'viewer was open.',
          ),
        (_, null) => const _ViewerNotice(
            title: 'Still stitching',
            message: 'The panorama is not written yet. The plan shows how far '
                'along it is.',
          ),
        (final CaptureMarker m, final String p) => _Viewer(marker: m, path: p),
      },
    );
  }
}

class _Viewer extends StatefulWidget {
  const _Viewer({required this.marker, required this.path});

  final CaptureMarker marker;
  final String path;

  @override
  State<_Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<_Viewer> {
  /// Gyro look, off by default.
  ///
  /// The two input modes cannot both be live: the pose stream writes the
  /// controller's yaw and pitch on every sample at ~100 Hz, so with the gyro on
  /// a drag is overwritten before the finger lifts and the view simply does not
  /// respond to touch.
  ///
  /// Drag wins the default because it is the one that always works — every
  /// device has a touchscreen, not every device's gyro is usable, and a
  /// panorama is often looked at flat on a table. Gyro is a deliberate choice
  /// on the button, and it is genuinely better when pointing at something on
  /// site.
  bool _gyro = false;

  @override
  Widget build(BuildContext context) {
    final CaptureMarker marker = widget.marker;
    final String path = widget.path;
    final String? previewPath = marker.previewPath;

    return Column(
      children: <Widget>[
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: SphereViewer(
                  image: File(path),
                  // Shown while the full-resolution texture uploads. Passed
                  // explicitly rather than left to the package's default
                  // because the panorama and its preview live in the same
                  // directory here and the default derivation would find it
                  // anyway — being explicit means a rename cannot quietly turn
                  // the fast first paint off.
                  previewImage: previewPath == null || previewPath == path
                      ? null
                      : File(previewPath),
                  showControls: true,
                  gyroscopeEnabled: _gyro,
                  onWarning: (String warning) {
                    // The package says so when the device has no usable gyro.
                    // Fall back rather than leaving a toggle that does nothing.
                    if (mounted) setState(() => _gyro = false);
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(content: Text(warning)));
                  },
                  errorBuilder: (BuildContext context, Object error) =>
                      _ViewerNotice(
                    title: 'This panorama could not be opened',
                    message: '$error',
                  ),
                ),
              ),
              Positioned(
                left: AppSizes.md,
                top: AppSizes.md,
                child: _LookModeToggle(
                  gyro: _gyro,
                  onChanged: (bool value) => setState(() => _gyro = value),
                ),
              ),
            ],
          ),
        ),
        if (marker.stitch == SphereStitchState.failed)
          _StitchFailedStrip(error: marker.stitchError),
        _ReportStrip(marker: marker),
      ],
    );
  }
}

/// Drag or gyro. One at a time, because the gyro overwrites the drag.
class _LookModeToggle extends StatelessWidget {
  const _LookModeToggle({required this.gyro, required this.onChanged});

  final bool gyro;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.alpha(AppColors.capturePill, 0.85),
      borderRadius: BorderRadius.circular(AppSizes.radiusPill),
      child: InkWell(
        onTap: () => onChanged(!gyro),
        borderRadius: BorderRadius.circular(AppSizes.radiusPill),
        child: Container(
          constraints: const BoxConstraints(
            minHeight: AppSizes.minTouchTarget,
          ),
          padding: const EdgeInsets.symmetric(horizontal: AppSizes.md),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                gyro ? Icons.screen_rotation_outlined : Icons.pan_tool_outlined,
                size: 16,
                color: AppColors.onChrome,
              ),
              const SizedBox(width: AppSizes.sm),
              Text(
                gyro ? 'Move the phone' : 'Drag to look',
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: AppColors.onChrome),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the stitch measured, in the pipeline's own numbers.
///
/// Kept on screen rather than in a log because the question it answers arrives
/// months later — "why is this defect soft" — and by then the only record is
/// whatever was persisted with the panorama.
class _ReportStrip extends StatelessWidget {
  const _ReportStrip({required this.marker});

  final CaptureMarker marker;

  StitchReport? get _report {
    final String? raw = marker.reportJson;
    if (raw == null) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return StitchReport.fromJson(decoded.cast<String, Object?>());
    } on Object {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final StitchReport? report = _report;

    if (report == null) {
      // A preview has landed but the full pass has not. Saying so is better
      // than an empty strip, because the panorama on screen is genuinely a
      // lower-resolution one and it should not be mistaken for the deliverable.
      return const _Strip(
        children: <Widget>[
          _Metric(label: 'Quality', value: 'Preview'),
          _Metric(label: 'Full stitch', value: 'Pending'),
        ],
      );
    }

    return _Strip(
      children: <Widget>[
        _Metric(
          label: 'Coverage',
          value: Formatters.percent(report.coverageFraction),
        ),
        _Metric(
          label: 'Join error',
          value: '${report.rmsReprojectionErrorPx.toStringAsFixed(1)} px',
        ),
        _Metric(label: 'Size', value: report.tierUsed.name),
        if (report.warnings.isNotEmpty)
          _Metric(label: 'Warnings', value: '${report.warnings.length}'),
      ],
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.chrome,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSizes.md,
            vertical: AppSizes.md,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: children,
          ),
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label.toUpperCase(),
          style: AppTypography.sectionLabel.copyWith(
            color: AppColors.onChromeMuted,
            fontSize: 10,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: AppTypography.mono.copyWith(
            fontSize: 13,
            color: AppColors.onChrome,
          ),
        ),
      ],
    );
  }
}

class _StitchFailedStrip extends StatelessWidget {
  const _StitchFailedStrip({this.error});

  final String? error;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppColors.dangerContainer,
      padding: const EdgeInsets.all(AppSizes.md),
      child: Text(
        'The full-resolution stitch failed, so this is the preview. '
        '${error ?? ''}'.trim(),
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: AppColors.onDangerContainer),
      ),
    );
  }
}

class _ViewerNotice extends StatelessWidget {
  const _ViewerNotice({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              title,
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
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
      ),
    );
  }
}

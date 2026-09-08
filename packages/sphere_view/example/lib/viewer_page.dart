import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sphere_view/sphere_view.dart';

/// Flow 3 and flow 5: look around the panorama, then export it.
///
/// The gyro toggle is the reason this is a screen rather than a dialog. Gyro
/// look is the mode the package was built for — a manager holding a tablet up
/// and turning on the spot sees the sphere move with the room — and it is also
/// the mode that goes wrong invisibly, because a mirrored conversion produces a
/// view that looks entirely plausible until you turn towards something you can
/// name. Put it under a switch and it gets tested on every device the demo runs
/// on.
class ViewerPage extends StatefulWidget {
  /// Shows [file], which must already carry its XMP GPano block.
  const ViewerPage({super.key, required this.file, required this.title});

  /// The equirectangular JPEG.
  final File file;

  /// The station's name, for the app bar.
  final String title;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  bool _gyro = false;
  PanoramaMetadata? _metadata;
  String? _warning;
  String? _exportStatus;

  /// Flow 5. The share sheet is the honest test of criterion S10: whatever
  /// comes back from "Save to Photos" or "Copy to Google Photos" is being read
  /// by somebody else's XMP parser, not ours.
  Future<void> _export() async {
    setState(() => _exportStatus = 'Exporting…');
    try {
      final metadata = _metadata;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(widget.file.path, mimeType: 'image/jpeg')],
          subject: widget.title,
          text: metadata == null
              ? widget.title
              : '${widget.title} — ${metadata.fullWidth}×${metadata.fullHeight} '
                    'equirectangular, GPano written',
        ),
      );
      if (mounted) {
        setState(
          () => _exportStatus =
              'Shared. Open it in Google Photos: if it appears as a sphere you '
              'can drag around rather than a very wide photo, the GPano block '
              'is right (S10).',
        );
      }
    } on Object catch (error) {
      if (mounted) setState(() => _exportStatus = 'Export failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final metadata = _metadata;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Export the equirect',
            onPressed: _export,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SphereViewer(
              // A new key on every toggle: `gyroscopeEnabled` decides whether
              // the viewer subscribes to the pose stream at all, and the point
              // of the switch is to watch it start and stop.
              key: ValueKey(_gyro),
              image: widget.file,
              gyroscopeEnabled: _gyro,
              showControls: true,
              onMetadata: (m) {
                if (mounted) setState(() => _metadata = m);
              },
              onWarning: (w) {
                if (mounted) setState(() => _warning = w);
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _gyro,
                    onChanged: (value) => setState(() => _gyro = value),
                    title: const Text('Gyro look'),
                    subtitle: Text(
                      _gyro
                          ? 'Turn on the spot — the view follows the tablet.'
                          : 'Drag to look around; pinch to zoom.',
                    ),
                  ),
                  if (metadata != null)
                    Text(
                      'GPano: ${metadata.fullWidth}×${metadata.fullHeight}'
                      '${metadata.heading.isKnown ? ', heading '
                            '${metadata.heading.degrees!.toStringAsFixed(1)}° '
                            '(${metadata.heading.source.name})' : ', no heading'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (_warning != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _warning!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (_exportStatus != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _exportStatus!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

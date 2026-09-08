import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Every path a sphere capture touches, in one place.
///
/// The layout is deliberate rather than incidental:
///
/// ```
/// <application support>/spheres/
///   captures.json          the markers, so a pin survives a restart
///   stitch_queue.json      written by sphere_view's StitchQueue
///   bundles/<sessionId>/   the raw capture — a few hundred MB, and deleted
///                          when its stitch met its quality targets
///   panoramas/<sessionId>.jpg          the panorama
///   panoramas/<sessionId>-preview.jpg  written by the pipeline beside it
/// ```
///
/// The preview's name is derived from the panorama's by the package, not chosen
/// here — `StitchQueueEntry.previewPathFor` is the single definition of that
/// rule, and a second copy of it in this app is a second thing that can drift.
/// The symptom of drift is an orphaned file or a missing preview, so anything
/// that needs the path must call that method rather than spell the suffix.
///
/// Panoramas live **outside** the bundle directory on purpose. The package's
/// storage policy deletes a bundle once its stitch came out well, and a
/// panorama written inside it would go with it.
///
/// Application support rather than temporary or cache: the OS may reclaim both
/// of those without asking, and a site visit costs more than every tablet in
/// the fleet's storage put together.
class SphereStorage {
  const SphereStorage(this.root);

  /// `<application support>/spheres`.
  final Directory root;

  /// Opens the storage root, falling back to a temporary directory.
  ///
  /// The fallback is not a nicety. Every other feature in this app — sign in,
  /// the plan, issues, the upload queue — is reachable without a single sphere,
  /// and `main` resolves this before `runApp`, so an exception here is a device
  /// that shows the native splash screen forever with no message. A capture
  /// that does not survive a reboot is a much smaller failure than an app that
  /// does not start, and this one is loud in the log rather than silent.
  static Future<SphereStorage> open() async {
    Directory parent;
    try {
      parent = await getApplicationSupportDirectory();
    } on Object catch (error) {
      debugPrint(
        'No application-support directory ($error). Captures will go to a '
        'temporary directory and may not survive a reboot.',
      );
      parent = Directory.systemTemp;
    }

    final Directory root = Directory(p.join(parent.path, 'spheres'));
    await root.create(recursive: true);
    await Directory(p.join(root.path, 'bundles')).create(recursive: true);
    await Directory(p.join(root.path, 'panoramas')).create(recursive: true);
    return SphereStorage(root);
  }

  /// Where the queue keeps its own state file.
  Directory get queueDirectory => root;

  File get captureStoreFile => File(p.join(root.path, 'captures.json'));

  Directory bundleDirectory(String sessionId) =>
      Directory(p.join(root.path, 'bundles', sessionId));

  /// The output path handed to the queue. The pipeline derives the preview's
  /// name from this one, which is why it is not chosen independently.
  String panoramaPath(String sessionId) =>
      p.join(root.path, 'panoramas', '$sessionId.jpg');

  /// Deletes every bundle and every panorama, and empties the queue file.
  ///
  /// Only the demo console calls this. It is separate from the console's
  /// general reset because that one throws away mock objects and this one
  /// throws away gigabytes of somebody's morning.
  Future<void> deleteEverything() async {
    for (final String name in const <String>['bundles', 'panoramas']) {
      final Directory dir = Directory(p.join(root.path, name));
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }
    final File queueFile = File(p.join(root.path, 'stitch_queue.json'));
    if (await queueFile.exists()) await queueFile.delete();
  }
}

/// Resolved in `main()` and injected, so that nothing downstream has to be
/// asynchronous just to know where a file goes. Tests override it with a
/// temporary directory.
final sphereStorageProvider = Provider<SphereStorage>((ref) {
  throw StateError(
    'sphereStorageProvider was read without being overridden. main() resolves '
    'it before runApp; a test must override it with a temporary directory.',
  );
});

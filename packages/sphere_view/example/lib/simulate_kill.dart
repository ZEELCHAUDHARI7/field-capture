import 'dart:io';

import 'package:flutter/material.dart';

/// The debug button flow 7 asks for: kill the app, right now, from wherever
/// you are.
///
/// It calls `exit(0)`, which is a real process termination rather than a
/// simulation of one. That is deliberate, and it is the only version of this
/// button worth having: the properties being demonstrated are that
/// `bundle.json` was rewritten atomically after the last accepted position and
/// that the queue file already said a bundle was in flight, and both of those
/// are claims about what survives when the process stops without warning. A
/// button that tore down some in-memory state and rebuilt it would be testing
/// the demo, not the package.
///
/// It is safe to press at any moment for exactly the same reason: frames go to
/// disk as the platform returns them, the manifest is written by temp-file and
/// rename, and the queue writes `running` *before* the work starts rather than
/// after it.
class SimulateKillButton extends StatelessWidget {
  /// Creates the button.
  const SimulateKillButton({super.key, this.label = 'Simulate app kill'});

  /// The button's text.
  final String label;

  /// Ends the process.
  ///
  /// Separated so the widget test can prove the button is wired to something
  /// without the test runner exiting.
  static void kill() => exit(0);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      shape: const StadiumBorder(
        side: BorderSide(color: Colors.white24),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () => _confirm(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bolt, size: 16, color: Colors.white),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirm(BuildContext context) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kill the app?'),
        content: const Text(
          'The process ends immediately, as if the system had reclaimed it. '
          'Reopen the app: a half-finished capture comes back as a station you '
          'can resume, and a stitch that was running goes back into the queue.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Kill it'),
          ),
        ],
      ),
    );
    if (go == true) kill();
  }
}

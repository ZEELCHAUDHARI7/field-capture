import 'package:flutter/foundation.dart';

import '../../plan/models/plan_document.dart';

/// Where the 3D geometry comes from.
///
/// The same swap point as `PlanSource`, for the same reason: the prototype
/// never states the model's source, format or size, and never draws a loading,
/// failure or no-model state. See ASSUMPTIONS.md §B7 and §I1.
sealed class PerspectiveSource {
  const PerspectiveSource();
}

/// PHASE 5 STAND-IN — the calibration's own plan, extruded to wall height.
///
/// Not a BIM model, and not pretending to be one. It is the only spatial data
/// this app actually holds, so walls land where the plan says walls are and
/// walking the trajectory shows the right rooms in the right order. That is
/// enough to build and review every interaction in the deck — the scrub, the
/// yaw, the mini plan, the compare wipe — without waiting on a format decision.
class ExtrudedPlanSource extends PerspectiveSource {
  const ExtrudedPlanSource({
    required this.document,
    this.wallHeightMetres = 2.8,
  });

  final PlanDocument document;

  /// Slab-to-soffit. Not specified anywhere — ASSUMPTIONS.md §I2.
  final double wallHeightMetres;
}

/// The production path, once Asite names a format.
///
/// Deliberately left as a marker rather than a guess: adding a 3D engine before
/// knowing whether the model is IFC, glTF, a point cloud or server-rendered
/// tiles would be committing the project to the wrong dependency.
@immutable
class ModelPerspectiveSource extends PerspectiveSource {
  const ModelPerspectiveSource({required this.modelUri});

  final String modelUri;
}

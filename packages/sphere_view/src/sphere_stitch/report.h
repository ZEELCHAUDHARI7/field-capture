// report.h — turns a RegistrationResult into the JSON `StitchReport`
// deserialises from.
//
// Split out from the pipeline because §6 of the phase doc treats the report as
// a deliverable in its own right: it is what turns "perfect" from an opinion
// into a number, both in the Phase 02 harness and in the field. Architecture §8
// puts it more sharply — never silently degrade; every compromise lands here.

#ifndef SV_REPORT_H
#define SV_REPORT_H

#include <string>

#include "compositing.h"
#include "hdr_fuse.h"
#include "registration.h"
#include "sv_json.h"

namespace sv {

/// Builds the report object.
///
/// [intrinsics] is the camera **as captured**, before any stage-5 downscale, so
/// that `refined_intrinsics` describes the camera that took the photos rather
/// than the resized frames the solver happened to be handed. [hdr] carries the
/// scale needed to undo that, and is null only for a refusal raised before stage
/// 5 ran.
///
/// [compositing] is null when the run stopped after registration — the
/// `registration_only` diagnostic, or a failure before stage 10. The
/// photometric criteria are then emitted as explicit sentinels with a warning
/// rather than as plausible zeros, because a zero in a metrics table reads as
/// "perfect" and would quietly turn a stage that never ran into a passing
/// grade.
Json buildReport(const RegistrationResult& result,
                 const Intrinsics& intrinsics,
                 const std::string& tier,
                 int elapsedMs,
                 const CompositingResult* compositing,
                 const HdrFuseResult* hdr);

}  // namespace sv

#endif  // SV_REPORT_H

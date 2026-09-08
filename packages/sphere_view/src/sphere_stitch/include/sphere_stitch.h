// sphere_stitch.h — the entire public surface of the native pipeline.
//
// One entry point, JSON in, file out (architecture §6.4). JSON rather than a
// packed struct because the ABI would otherwise break every time a field is
// added — bracket count, distortion coefficients, quality tier — and the cost,
// parsing a few KB once, is irrelevant next to a 40-second stitch.
//
// Consumed by three callers that must not diverge: the Android plugin, the iOS
// plugin, and tools/replay on the desktop. PHASE_02 §2 requires replay to run
// this same library, or the harness is measuring something the device never
// runs.

#ifndef SPHERE_STITCH_H
#define SPHERE_STITCH_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SV_EXPORT __attribute__((visibility("default")))

// `noexcept` in C++, nothing in C. Part of the ABI rather than an implementation
// detail: an exception unwinding out of sv_stitch would cross into Dart's
// frames, which is undefined behaviour (Phase 10 §4), so the promise not to
// throw belongs in the declaration the caller reads.
#ifdef __cplusplus
#define SV_NOEXCEPT noexcept
#else
#define SV_NOEXCEPT
#endif

// Gates request/report compatibility. Bump only when the JSON contract changes
// in a way an older reader would misinterpret — a silently different meaning is
// the failure this exists to prevent.
#define SV_SCHEMA_VERSION 1

// Return codes. Negative is failure; the human-readable reason is written to
// error_buf. Distinct codes exist so the Dart side can decide what to retry:
// a cancelled stitch is not an error to report to the user, and a plan that
// cannot be registered is not the same as a corrupt bundle.
#define SV_OK                  0
#define SV_ERR_BAD_JSON       -1   // request_json is not parseable
#define SV_ERR_SCHEMA         -2   // schema_version disagrees with this build
#define SV_ERR_NO_FRAMES      -3   // bundle contains nothing to stitch
#define SV_ERR_IO             -4   // a frame or the output path is unreadable
#define SV_ERR_REGISTRATION   -5   // BA failed outright; see warnings
#define SV_ERR_CANCELLED      -6   // caller set SvProgress.cancel
#define SV_ERR_INSUFFICIENT   -7   // plan too sparse to register — actionable
#define SV_ERR_INTERNAL       -8   // a bug in us; the message says where

// The three codes below exist only because an exception must never cross this
// boundary: unwinding into Dart's frames is undefined behaviour and takes the
// app with it, so sv_stitch is `noexcept` and every throw is turned into one of
// these (Phase 10 §4).
//
// SV_ERR_OUT_OF_MEMORY is the one the caller acts on rather than reports: it is
// the signal to drop a tier and retry once (architecture §8). It covers both
// std::bad_alloc and OpenCV's cv::Error::StsNoMem, because OpenCV's allocator
// does *not* throw std::bad_alloc — cv::fastMalloc raises a cv::Exception —
// and at 8192x4096 the allocation that fails is virtually always OpenCV's.
// Mapping only std::bad_alloc would leave the retry path dead on the exact
// device the tier table exists for.
#define SV_ERR_OUT_OF_MEMORY  -9   // allocation failed; drop a tier and retry
#define SV_ERR_OPENCV        -10   // a cv::Exception that is not an allocation
#define SV_ERR_UNKNOWN       -11   // something not derived from std::exception

// Stage ordinals. **These are the StitchStage enum in
// lib/src/api/models/stitch_progress.dart and the two must move together.**
// Dart reads the stage back as StitchStage.values[stage], so inserting a value
// here silently remaps every progress report the user sees.
#define SV_STAGE_FUSING           0
#define SV_STAGE_UNDISTORTING     1
#define SV_STAGE_FINDING_FEATURES 2
#define SV_STAGE_MATCHING         3
#define SV_STAGE_ADJUSTING        4
#define SV_STAGE_WARPING          5
#define SV_STAGE_COMPENSATING     6
#define SV_STAGE_SEAMING          7
#define SV_STAGE_BLENDING         8
#define SV_STAGE_FILLING_POLES    9
#define SV_STAGE_ENCODING        10

/// The shared-memory progress triple (architecture §6.3).
///
/// Deliberately three plain int32s rather than an FFI callback. The stitch runs
/// on a worker isolate, and calling back into Dart from a C++ thread needs a
/// `NativeCallable.listener` bound to that isolate, which is fragile across the
/// isolate's lifecycle. Here C++ only ever writes [stage] and [permille], Dart
/// polls them at 10 Hz, and Dart only ever writes [cancel]. No locks, no
/// lifetime hazards, and cancellation that actually works.
///
/// Each field is written and read as a whole aligned int32, so a reader can
/// observe a stale value but never a torn one — which is all the polling
/// consumer needs.
typedef struct {
    int32_t stage;     ///< SV_STAGE_*, written by C++.
    int32_t permille;  ///< 0..1000 *within* the current stage, written by C++.
    int32_t cancel;    ///< non-zero to abort, written by Dart, polled by C++.
} SvProgress;

/// Runs the pipeline described by [request_json].
///
/// [request_json] is a UTF-8 JSON object:
///
///     {
///       "schema_version": 1,
///       "bundle_dir":  "/abs/path/to/bundle",   // frames resolve against this
///       "output_path": "/abs/path/out.jpg",     // ignored when registration_only
///       "tier": "low" | "mid" | "high",
///       "registration_only": true,              // stop after stage 9
///       "bundle": { ...verbatim bundle.json... }
///     }
///
/// [progress] may be NULL when the caller does not care; every write is
/// null-checked. Passing it is what makes cancellation possible, so the isolate
/// path always passes one.
///
/// On success writes a newly allocated JSON report to *[report_json_out], which
/// deserialises straight into `StitchReport`. **The caller owns it and must
/// release it with [sv_free]** — it is allocated by this library, so it has to
/// be freed by this library's allocator, not the caller's.
///
/// On failure returns one of the SV_ERR_* codes and writes a NUL-terminated
/// message into [error_buf]. A report may still be produced on a *partial*
/// failure, because architecture §8's rule is never to degrade silently: a
/// stitch that dropped frames should hand back the numbers proving it.
SV_EXPORT int32_t sv_stitch(const char* request_json,
                            SvProgress* progress,
                            char* error_buf, int32_t error_buf_len,
                            char** report_json_out) SV_NOEXCEPT;

/// Releases a buffer handed out by [sv_stitch].
SV_EXPORT void sv_free(char* p);

/// Library version plus the OpenCV it was linked against, for the report
/// header. Static storage; do not free. Worth having because "which OpenCV did
/// this run use" is the first question when desktop replay and device disagree.
SV_EXPORT const char* sv_version(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // SPHERE_STITCH_H

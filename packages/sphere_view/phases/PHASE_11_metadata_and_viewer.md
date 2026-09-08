# Phase 11 — Output metadata and the 360 viewer

**Goal:** an output file that any standard photo-sphere viewer recognises, and a
built-in viewer good enough that nobody needs another one.

**Duration:** 3–4 days. **Depends on:** 04, 10.

---

## 1. Why metadata is not a detail

Without XMP GPano, the output is "a wide JPEG". With it, the same file opens as an
interactive sphere in Google Photos, Facebook, Street View, Marzipano, Pannellum,
and every asset viewer that supports photo spheres. For a construction record that
will be attached to a plan and opened by people who do not have our app, that
difference is most of the value.

This is criterion **S10**, and it costs about a day.

---

## 2. `gpano_writer.dart`

Write the XMP packet per §5 of
[01_MATH_AND_CONVENTIONS.md](01_MATH_AND_CONVENTIONS.md). JPEG carries XMP in an
`APP1` segment with the `http://ns.adobe.com/xap/1.0/\0` header.

```
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:GPano="http://ns.google.com/photos/1.0/panorama/">
   <GPano:ProjectionType>equirectangular</GPano:ProjectionType>
   <GPano:UsePanoramaViewer>True</GPano:UsePanoramaViewer>
   <GPano:FullPanoWidthPixels>6144</GPano:FullPanoWidthPixels>
   <GPano:FullPanoHeightPixels>3072</GPano:FullPanoHeightPixels>
   <GPano:CroppedAreaImageWidthPixels>6144</GPano:CroppedAreaImageWidthPixels>
   <GPano:CroppedAreaImageHeightPixels>3072</GPano:CroppedAreaImageHeightPixels>
   <GPano:CroppedAreaLeftPixels>0</GPano:CroppedAreaLeftPixels>
   <GPano:CroppedAreaTopPixels>0</GPano:CroppedAreaTopPixels>
   <GPano:PoseHeadingDegrees>127.5</GPano:PoseHeadingDegrees>
   <GPano:PosePitchDegrees>0</GPano:PosePitchDegrees>
   <GPano:PoseRollDegrees>0</GPano:PoseRollDegrees>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
```

`PosePitchDegrees` and `PoseRollDegrees` are exactly 0 because Phase 03 §5 already
levelled the panorama against measured gravity. If they are ever non-zero, that is
a bug in levelling, not something to paper over here.

### Segment insertion

Insert `APP1`/XMP **immediately after `SOI`**, before any existing `APP0`/JFIF or
`APP1`/EXIF. Some readers only scan the first few segments. If the file already has
an XMP `APP1` (OpenCV's encoder does not add one, but be defensive), replace rather
than append — duplicate XMP packets make some readers ignore both.

Watch the 64 KB segment size limit. Our packet is ~1 KB, so extended XMP is not
needed, but assert it rather than assume.

### EXIF

Also write, in an `APP1`/EXIF segment:

- `DateTimeOriginal` — capture start
- `Make` / `Model` — from device info
- `GPSLatitude` / `GPSLongitude` / `GPSAltitude` — when a fix is available
- `GPSImgDirection` + `GPSImgDirectionRef` — same heading as `PoseHeadingDegrees`
- `ImageDescription` — station id / plan reference, for the site-walk integration
- `Software` — `sphere_view <version>`

### Heading source, in priority order

1. **The plan.** For the site-walk feature (Phase 13), the manager's facing
   direction is derivable from the path they drew, and the plan's north is known.
   This is by far the most accurate source and it costs the user nothing.
2. Magnetometer heading at session start, averaged over the metering sweep. Rough
   indoors (architecture §1.1) but better than nothing.
3. Omit `PoseHeadingDegrees` entirely. Viewers then open at yaw 0, which is the
   session-start heading — still meaningful, just not north-referenced.

Never write a magnetometer heading as though it were reliable. If it is used,
record the source in the report so a wildly wrong opening direction is diagnosable.

### Tests

- write → read back with an independent parser; every field round-trips
- output opens as a sphere in Google Photos (manual, once per format change)
- `exiftool` reports `Projection Type: equirectangular` and a valid GPano block
- packet inserted before existing APP segments; file remains a valid JPEG
- a file that already contains XMP gets it replaced, not duplicated

`exiftool` in CI is the cheap automated proxy for "does a real viewer accept it".

---

## 3. The viewer

The existing GPU viewer (`lib/src/viewer/`) is the one part of the current package
that is architecturally sound: a fragment shader sampling an equirect texture by
ray direction. Keep the approach; fix what a 6144×3072 image exposes.

### 3.1 Texture size is the real problem

A 6144×3072 RGBA texture is 75 MB of VRAM; 8192×4096 is 134 MB. Many mid-range
tablet GPUs cap `GL_MAX_TEXTURE_SIZE` at 4096, so an 8192-wide texture **fails to
upload at all** — and the failure mode is a black sphere, not an error.

Required:

1. Query the max texture size and downscale on upload if needed.
2. **Progressive loading**: display the 2048×1024 preview (Phase 04 §7)
   immediately, then swap in full resolution once decoded. The preview appears in
   ~50 ms instead of 800 ms, which is the difference between "instant" and
   "sluggish".
3. Decode off the UI thread (`instantiateImageCodec` with `targetWidth`).
4. For `high` tier, consider a cubemap or tiled representation. **Defer** — only
   build it if measurement shows it is needed. A single downscaled equirect is
   likely fine and is much simpler.

### 3.2 Interaction

- **Drag** to look (inverted: dragging left turns the view right, matching every
  other panorama viewer).
- **Pinch** to zoom, FOV clamped to 30°–100°. Below 30° the source resolution runs
  out and it looks broken; above 100° the projection distortion is unpleasant.
- **Optional gyro look** — hold the tablet up and look around by moving it. Uses
  the same `PoseSource` as capture (Phase 07), so it is nearly free. Off by
  default, one small toggle; it is delightful but disorienting if unexpected.
- **Pitch clamp** to ±90° with a soft stop, so the user cannot roll past the pole
  and end up upside down.
- **Open at `PoseHeadingDegrees`** when present, else yaw 0.
- Double-tap to reset view.

### 3.3 Correctness

The viewer must use the **exact same mapping** as §3 of the math doc. A sign flip
here produces a mirrored view that looks plausible and would silently invalidate
every visual review of the stitcher's output.

Guard: a golden test rendering a synthetic equirect containing labelled direction
markers (`N`/`E`/`S`/`W`, zenith, nadir) at known yaw/pitch, asserting each appears
where the formula says. Same technique as Phase 02 §4, applied to the viewer.

### 3.4 Tests

- golden test: direction markers land at their computed screen positions for six
  camera orientations
- max-texture-size path: an 8192 image on a 4096-limited GPU renders (downscaled),
  does not go black
- progressive load: preview visible within 100 ms
- pinch clamps at 30° and 100°
- pitch clamps at ±90°; no upside-down state reachable
- 60 fps sustained while dragging, at every tier, on the lowest-end target device
- gyro look toggles cleanly and does not leak the sensor subscription

---

## 4. Deleting the old stitcher

This phase is the point at which `lib/src/stitching/equirectangular_stitcher.dart`
is deleted. Before deleting, confirm its push–pull fill has been ported to C++
(Phase 04 §6) — that algorithm is genuinely good and is the one thing worth
keeping from it.

Also remove `lib/sphere_capture.dart` / `lib/sphere_viewer.dart` if the Phase 01
barrel has superseded them, and update the README so its example matches the
shipped API.

---

## Exit criteria

- [ ] Output opens as an interactive sphere in Google Photos and Facebook —
      **manual, still owed.** `exiftool` is the automated proxy and passes; only
      a real viewer proves acceptance. Procedure in
      `example/integration_test/RUNNING.md` §9c
- [x] `exiftool` validation in CI — `tools/ci/validate_metadata.sh`, run by
      `quality_gate.sh`. Passes on real stitched output with **no warnings**
- [x] All seven viewer tests pass, including the direction-marker golden —
      `viewer_mapping_test.dart` (6 orientations) and `viewer_test.dart`. The
      golden was **verified by mutation**: against `atan(-dir.x, -dir.z)` it goes
      red, and 4 of the 6 orientations survive the flip, which is why the E/W
      markers and the explicit mirror test exist
- [ ] Viewer holds 60 fps at every tier on the lowest-end target device —
      **needs a device.** Measured by
      `example/integration_test/viewer_device_test.dart` §3, against the
      display's real refresh rate and on **raster** duration
- [ ] 8192-wide output renders on a 4096-max-texture GPU — **needs a device**
      for the upload itself; the downscale arithmetic and the limit probe are
      covered on desktop. `viewer_device_test.dart` §2 asserts the rendered
      sphere is not black
- [x] Old stitcher deleted; push–pull fill confirmed ported — it is
      `src/sphere_stitch/pole_fill.cpp`, wrap-aware and `cos(pitch)`-weighted,
      called from `compositing.cpp` and covered by two native tests
- [x] README example matches the real API and compiles —
      `test/readme_snippet_test.dart` compiles every snippet and asserts the
      clamps the prose states as fact

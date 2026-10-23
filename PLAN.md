# Plan

Order matters: each milestone is usable on its own.

## M0 — Builds and runs (≈ an hour) ✅
- `xcodegen generate`, fix compile errors, app launches in simulator showing the import screen.
- `scripts/test.sh` green (one trivial test).
- Decide the image backend (see Decisions).

## M1 — Import photos → flat board (the core; simulator-testable) ✅
- Home screen: pick 2–6 photos (PhotosPicker), order them left→right (drag to reorder; later: auto).
- Port `reference/whiteboard_pipeline.py` to Swift behind the protocols in `Pipeline/`:
  register (full + thin-overlap fallback) → blend → find VPs → rectify → crop.
- Result view: pinch-zoom, toggle "full / cropped", Save to Photos, Share.
- Warn on low-confidence joins (inlier count below threshold) and say which pair.
- Tests with `fixtures/` (no UI needed): stage outputs vs expected within tolerance.
Run heavy work off the main actor; downscale for matching, warp at full-res.

## M2 — Guided capture (needs a real iPhone) ✅ (works on device; video import not yet tried)
Tuning knobs after the first real sweeps: `KeyframePolicy` thresholds, `PoseRegistrar.maxRefinementDeviation`.
- ARKit `ARWorldTrackingConfiguration` with vertical plane detection; show live overlay of already-covered area.
- Take a keyframe automatically when the camera has moved ~X cm / rotated ~Y° (aim 30% overlap), reject blurry frames
  (variance of Laplacian), lock exposure/white balance to avoid brightness steps.
- Save keyframes + camera pose + intrinsics. Initial homography between frames from plane-induced homography
  `H = K (R − t nᵀ/d) K⁻¹`; refine with feature matching; fall back to M1 registration if tracking is poor.
- Also support "just record a video and sweep": pick keyframes from video by motion (no ARKit poses → use M1 registration).

## M3 — Better flattening — done (plane rectification in M2; corner editor), awaiting device test
- With an ARKit plane: rectify from plane normal + gravity instead of VP estimation.
- Manual fallback: 4 draggable corners.
- Keep the VP method for imported photos.

## M4 — Image quality — done except OCR, awaiting device test
- Glare reduction from overlapping frames; background whitening / contrast so ink is crisp; optional "scan" mode (B/W-ish).
- Seam blending (multi-band) and exposure compensation (the prototype only feathers + global gain).
- Export PNG/JPEG/PDF. Optional later: Vision OCR for searchable text; saving a history of boards.

## Decisions to make early (propose, then ask Zac only if it's a real fork)
1. **Backend**: OpenCV (SIFT, findHomography, estimateAffinePartial2D, HoughLinesP — 1:1 with the prototype; adds a ~dozens-of-MB
   dependency; check current SPM/xcframework options) vs pure Apple (Vision `VNHomographicImageRegistrationRequest`, Core Image,
   Accelerate; smaller, but VP/line detection and robust matching must be hand-built). Recommendation: OpenCV for M1, hidden behind protocols.
   → **Decided: OpenCV 4.13** (`yeatse/opencv-spm` binary xcframework).
2. Min iOS target: suggest 17. → 17.
3. App name / bundle id: ~~placeholder~~ → **`uk.co.zacgarby.whiteboard-scan`**.

## Risks
Thin overlap → bad joins (mitigated by capture guidance); glare; tracking drift over a wide board; handwriting baselines are not
perfectly horizontal (VP estimate is a median, fine); OpenCV binary size and build time.

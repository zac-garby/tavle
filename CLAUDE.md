# Whiteboard — iOS app

Wave an iPhone along a whiteboard → one flat, readable, full-board image.
Owner: Zac (PhD student, functional programming; fluent in Haskell/Lean, fine with Swift/Python).
Keep replies short; bring up things only if genuinely interesting or blocking.

## Status
M0–M2 done and tested on Zac's iPhone 16. M3 + M4 written and simulator-tested (46 tests), **not yet run on the device**:
- History: every board is a folder Documents/Boards/<id>/ (board.json, source photos, capture.json for scans,
  mosaic/full/cropped JPEGs). Failed boards keep their photos so they can be inspected, edited and re-flattened.
  Old Documents/Captures scans are imported as drafts on launch. Code in `History/`.
- M3: manual 4-corner editor on the mosaic (starts from the auto crop mapped back). ARKit plane rectification is in M2.
- M4: glare-aware two-band blend (CVBridge.mm: low band = weighted average at 1/8 scale, detail from the best frame;
  frames brighter than the darkest frame over plain board are down-weighted), robust ratio gains, background
  whitening / B&W "scan" enhancement, save to the "Whiteboards" album, share JPEG/PNG/PDF.
- Crop to the physical board frame (`detectBoardFrame`): per side, a sharp step in the median "distance from board
  colour" profile with a solid non-board band outside (rejects drawn dividers); sides without a visible frame keep
  the largest-valid-rectangle crop. Board flattened first, so frame edges are axis-aligned.
- "Content" framing: board crop cut to the ink's bounding box + 2.5% margin (`CVBridge.contentRect`, same background
  model as Whiten; drops dust and long edge strips). Cached as content.jpg, cleared when the board crop changes.
- Per-board look: `framing` + `enhancement` + per-framing `trims` (unit rect inside that framing's image, set by
  dragging edges in `TrimEditor`) live in board.json; the last framing/look picked is the default for new boards
  (UserDefaults). Home cards show `cover-<look>.jpg` (rendered in the board's look). Board screen: edit panel folds
  away (Edit ⇄ Done); landscape (`verticalSizeClass == .compact`) puts controls in a side column / rail, home dock
  moves to the trailing edge and cards flow into adaptive grid columns.
- Capture: first photo is always manual (`KeyframePolicy.manualFirst`), auto after. 0.5× lens = `UltraWideCaptureModel`
  (AVCaptureSession; ARKit world tracking can't use the ultra-wide): overlap from phase correlation of preview frames,
  photos go through the image-only pipeline. Captures are dense (trigger at 70% overlap, ~65% actual, max 14) so each
  photo also overlaps the one two along: `PoseRegistrar` matches adjacent pairs, bridges failures with skip-one
  matches, leaves out photos that match nothing (`RegistrationResult.toReference[i] == nil`), and places frames by a
  shortest-path tree over optical joins (pose-only joins as a last resort). `CVRegistrar` also skips one bad photo.
- UI: "Darkroom" design (dark-only, pastel-green `Theme.accent`, Liquid Glass via `View.glass(in:)` with a material
  fallback below iOS 26). Shared styles in `UI/Theme.swift`; home groups boards by date (`BoardSection.group`).
  Every screen has `#Preview`s backed by `BoardStore.preview()` (UI/PreviewData.swift). Mockups:
  https://claude.ai/artifact/NW6AZE5DCuM1NGT1oTqaNQ
- App Store prep (Oct 2026, paid developer account): checklist in `docs/app-store.md`. Screenshots come from
  `scripts/screenshots.py` (DEBUG `-WBShots` mode, `UI/Screenshots.swift`: real photos in `screenshots/boards/`,
  screens + captions in `screenshots/shots.json`, output in `screenshots/appstore/`).
- Not done (deliberately): OCR / searchable PDF, block-wise exposure compensation.
Backend: OpenCV 4.13 via SPM (`yeatse/opencv-spm`, pinned; 5.x moves features2d). Pixel work in
`Pipeline/OpenCV/CVBridge.mm` (ObjC++), geometry + decisions in Swift. Simulator test fixtures for scans/videos
are synthetic (`PoseCaptureTests`, `VideoTests` render the reference board through known cameras).
Gotcha: build products inside ~/Desktop pick up xattrs that break codesign — use the default DerivedData.

## Commands
```
brew install xcodegen          # once
xcodegen generate              # project.yml -> Whiteboard.xcodeproj (don't hand-edit the xcodeproj)
./scripts/test.sh              # build + unit tests on the simulator
xcrun simctl list devices available   # SIM="iPhone 17" by default; must match the SDK's iOS (26.4)
# Simulator demo without tapping PhotosPicker (DEBUG builds):
xcrun simctl launch "iPhone 17" uk.co.zacgarby.whiteboard-scan -WBPhotos $PWD/fixtures/input -WBAutoRun YES [-WBCorners YES]
#   also -WBVideo <file>, -WBCapture <scan dir> (see ContentView.loadDebugInputs)
#   -WBSamples YES: start with the preview sample boards instead of the real history
#   -WBEditing YES: open the board edit panel straight away
#   rotate the simulator: osascript -e 'tell application "System Events" to key code 123 using command down'
./scripts/screenshots.py [--reuse | --frame-only | --only home]   # App Store screenshots (see docs/app-store.md)
python3 reference/whiteboard_pipeline.py /tmp/out fixtures/input/1_left.jpeg fixtures/input/2_middle.jpeg fixtures/input/3_right.jpeg
```

## Hard constraints
- Simulator has **no camera and no ARKit world tracking**. Pipeline work is testable in the simulator
  (feed it fixture photos). Capture work needs a real iPhone (USB, free Apple ID provisioning is fine).
  When something needs the device, stop and tell Zac exactly what to tap/run.
- Everything on-device; no network, no accounts.
- Keep the pipeline behind protocols (`Pipeline/`) so the image backend (OpenCV vs Vision/CoreImage) is swappable.

## Lessons from the Python prototype (don't relearn these)
1. **Photo order matters.** OpenCV's `Stitcher` silently dropped a photo when files were in reverse order. Order frames explicitly
   (capture order, or sort by ARKit pose / match graph).
2. **Thin overlap**: the left↔middle pair overlapped by only ~10% (a few characters). Full-image SIFT homography was wrong
   (73 inliers, garbage extrapolation). Fix that worked: SIFT restricted to the overlap strips + CLAHE + low contrast threshold,
   then a *rigid similarity* (4 DoF), not a homography. Always surface a "low confidence join" warning; the real fix is the guided
   capture UI enforcing ~30% overlap.
3. Photos of a board are taken from different positions/zooms; registration to the middle frame (not a cylindrical/spherical
   panorama model — the board is a plane, the phone *translates*).
4. Mask bug: ink is dark; any "valid pixel" mask must fill holes (close + flood-fill) or the crop finder thinks text is empty space.
5. **Flattening** without knowing the camera: find the vertical vanishing point (frame edges, hand-drawn dividers) and horizontal
   vanishing point (text baselines, underlines, frame top) by RANSAC on Hough segments, send the horizon to infinity, make the
   two directions axis-aligned, keep the centre at original scale. Worked well on the fixtures. With ARKit you can instead use the
   detected vertical plane + gravity (better); keep the VP method as the fallback for imported photos.
6. Output both: full bounding box (black where no photo covers) and the largest all-valid rectangle.
7. Glare (white streaks from lights) is the main visual defect left. Overlapping frames can be combined (e.g. per-pixel median/min-glare) to reduce it.

## Acceptance
- `fixtures/input/*` through the Swift pipeline gives something visually equivalent to `fixtures/expected/flat_full.jpg`
  (straight text rows, verticals vertical, all 3 photos present, left join visible but plausible).
- Unit tests for geometry helpers (homography composition, VP intersection, rectifying matrix, largest-rectangle).
- No crashes on: 1 photo, 2 photos, photos with no overlap (report error, don't crash), very large photos (downscale internally).

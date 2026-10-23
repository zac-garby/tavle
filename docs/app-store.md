# App Store checklist

## Decisions (Zac)
- [ ] **Store name.** "Whiteboard" is certainly taken, and App Store names must be unique. The home-screen name
      (`CFBundleDisplayName`) can stay short. Also needs a subtitle of up to 30 characters.
- [x] iPhone only for now (`TARGETED_DEVICE_FAMILY: "1"`).
- [x] Free. Can change to paid later; that needs the Paid Apps agreement plus tax and banking forms.
- [ ] **EU trader status** (Digital Services Act; asked in App Store Connect). As a trader your address and phone
      number are shown on the EU store page. A free app with no business behind it can be declared non-trader.

## Must do
- [x] Team ID ZX7M3HPXGX (Zac says it's the paid team's).
- [ ] App record in App Store Connect (bundle ID `uk.co.zacgarby.whiteboard-scan`; automatic signing registers it).
- [ ] **App icon** (Zac is making it). A placeholder is in `Assets.xcassets/AppIcon.appiconset/icon-1024.png` so
      TestFlight uploads pass validation. Replace that PNG, or switch to an Icon Composer `.icon`.
- [ ] **Run M3/M4 on the device.** Use TestFlight: internal testers need no review, and it also tests the release build.
- [ ] Privacy policy URL (required even when nothing is collected) and a support URL. One page on zacgarby.co.uk covers both.
- [ ] App Privacy questionnaire: "Data Not Collected".
- [ ] Age rating questionnaire (all "none" gives 4+). Category: Productivity.
- [ ] Description, keywords (100 chars), promotional text, copyright line.
- [ ] Screenshots: 6.9" iPhone (1320×2868), 3–10 of them, from `scripts/screenshots.py` (below).
- [ ] App Review notes. The reviewer probably has no whiteboard: explain "Import → Photos" with 2–3 overlapping
      photos, and link to a few sample photos they can save.
- [ ] OpenCV is Apache-2.0, which requires shipping its licence notice. Add an Acknowledgements screen (or a Settings bundle).
- [x] Upload: `./scripts/testflight.sh` (archive + upload; the build number is a timestamp, the version is
      `MARKETING_VERSION` in project.yml). Or in Xcode: Product → Archive, then Distribute App.

## Done
- [x] `ITSAppUsesNonExemptEncryption = NO` (no export-compliance prompt on each build)
- [x] `PrivacyInfo.xcprivacy`: no tracking, no data collected; UserDefaults (CA92.1), file timestamps (C617.1)
- [x] Permission strings say what the camera and photo access are for

## Worth considering
- `UIFileSharingEnabled` puts the raw board folders (JSON, photos) in the Files app. That was handy for debugging,
  but decide whether it should ship.
- First-run hint on how to sweep. The empty state explains it, but it's the first thing a reviewer sees.

## Screenshots
`scripts/screenshots.py` builds a DEBUG app for the simulator (iPhone 17 Pro Max by default). It flattens every
folder in `screenshots/boards/`, opens each screen listed in `screenshots/shots.json` (captions live there too),
takes the screenshots with the status bar at 9:41, and adds captions. Output goes to
`screenshots/appstore/<device>/`. Run `--reuse` to reshoot without reflattening, `--frame-only` to recaption,
`--only home board` to redo some of them, and `SIM="iPad Pro 13-inch (M5)"` for iPad.
Board folder format: see `Sources/Whiteboard/UI/Screenshots.swift`.

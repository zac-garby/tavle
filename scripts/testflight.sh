#!/bin/bash
# Archive a Release build and upload it to App Store Connect (it then shows up in TestFlight after processing).
#   ./scripts/testflight.sh            archive + upload
#   ./scripts/testflight.sh --no-upload   archive + export an .ipa only (signing check)
# Needs: Xcode signed in to the paid account (Settings → Accounts), and the app record in App Store Connect.
# The build number is a timestamp, so every upload is newer than the last; the version is MARKETING_VERSION.
set -eo pipefail
cd "$(dirname "$0")/.."
unset LIBRARY_PATH CPATH   # shell profile points these at the macOS SDK, which breaks the iOS link
xcodegen generate

BUILD=$(date +%Y%m%d%H%M)
TEAM=$(awk '/DEVELOPMENT_TEAM:/ {print $2; exit}' project.yml)
ARCHIVE="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)/Whiteboard $BUILD.xcarchive"   # shows in Organizer
EXPORT="$HOME/Library/Developer/Xcode/DerivedData/Whiteboard-export/$BUILD"                      # not under ~/Desktop
DESTINATION=upload; [ "$1" = "--no-upload" ] && DESTINATION=export

OPTIONS=$(mktemp -t ExportOptions).plist
cat > "$OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF

xcodebuild -project Whiteboard.xcodeproj -scheme Whiteboard -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD" -quiet archive
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$OPTIONS" -allowProvisioningUpdates
echo "Build $BUILD: $( [ "$DESTINATION" = upload ] && echo "uploaded; it appears in TestFlight once processed (~10–30 min)" || echo "exported to $EXPORT" )"

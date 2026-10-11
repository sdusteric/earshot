#!/bin/bash
# Builds Earshot for Mac for release.
#   release-app.sh --local   Release build signed for this Mac, plus a DMG. No notarization.
#   release-app.sh           Developer ID build, notarized and stapled, a DMG, and the
#                            Sparkle appcast. Needs a "Developer ID Application" certificate,
#                            a notarytool profile (xcrun notarytool store-credentials earshot)
#                            and SPARKLE_PUBLIC_KEY from Sparkle's generate_keys.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); APP=$ROOT/app; OUT=$APP/build/release
fail() { echo "$*" >&2; exit 1; }
local_build=; [ "${1:-}" = --local ] && local_build=1
command -v xcodegen >/dev/null || fail "Needs XcodeGen: brew install xcodegen"
if [ -z "$local_build" ]; then
  security find-identity -v -p codesigning | grep -q "Developer ID Application" \
    || fail "No Developer ID Application certificate. Create one at developer.apple.com > Certificates, then run this again."
  xcrun notarytool history --keychain-profile earshot >/dev/null 2>&1 \
    || fail "No notarytool profile. Run: xcrun notarytool store-credentials earshot"
  [ -n "${SPARKLE_PUBLIC_KEY:-}" ] || fail "Set SPARKLE_PUBLIC_KEY (from Sparkle's generate_keys)."
fi
rm -rf "$OUT"; mkdir -p "$OUT"
xcodegen generate --spec "$APP/project.yml" --project "$APP" >/dev/null
ver=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' "$APP/project.yml")

if [ -n "$local_build" ]; then
  xcodebuild -project "$APP/Earshot.xcodeproj" -scheme Earshot -configuration Release \
    -derivedDataPath "$APP/build" build >"$OUT/build.log" 2>&1 || fail "Build failed: $OUT/build.log"
  cp -R "$APP/build/Build/Products/Release/Earshot.app" "$OUT/"
else
  xcodebuild -project "$APP/Earshot.xcodeproj" -scheme Earshot -configuration Release \
    -archivePath "$OUT/Earshot.xcarchive" SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" archive >"$OUT/build.log" 2>&1 \
    || fail "Archive failed: $OUT/build.log"
  xcodebuild -exportArchive -archivePath "$OUT/Earshot.xcarchive" -exportOptionsPlist "$APP/ExportOptions.plist" \
    -exportPath "$OUT" >>"$OUT/build.log" 2>&1 || fail "Export failed: $OUT/build.log"
  ditto -c -k --keepParent "$OUT/Earshot.app" "$OUT/Earshot.zip"
  xcrun notarytool submit "$OUT/Earshot.zip" --keychain-profile earshot --wait || fail "Notarization failed."
  xcrun stapler staple "$OUT/Earshot.app"
fi
codesign --verify --deep --strict "$OUT/Earshot.app" || fail "The app's signature does not verify."
echo "Signature OK"

# The DMG holds the app and a link to Applications, to drag it across.
dmg=$OUT/Earshot-$ver.dmg
stage=$OUT/dmg; mkdir -p "$stage"
cp -R "$OUT/Earshot.app" "$stage/"; ln -s /Applications "$stage/Applications"
if diskutil image create from --help >/dev/null 2>&1; then
  diskutil image create from --format UDZO --volumeName Earshot "$stage" "$dmg" >/dev/null 2>&1 \
    || fail "Couldn't make the disk image."
else
  hdiutil create -volname Earshot -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
fi
rm -rf "$stage"
if [ -z "$local_build" ]; then
  codesign --sign "Developer ID Application" "$dmg"
  xcrun notarytool submit "$dmg" --keychain-profile earshot --wait && xcrun stapler staple "$dmg"
  gen=$(find "$APP/build" -path '*Sparkle*/bin/generate_appcast' -type f | head -1)
  if [ -n "$gen" ]; then "$gen" "$OUT"; else echo "generate_appcast not found: build once with Xcode to fetch Sparkle's tools."; fi
fi
echo "Built $dmg"

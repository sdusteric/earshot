#!/bin/bash
# Builds and packages Earshot for Mac. See docs/RELEASE.md for the whole checklist.
#
#   release-app.sh --dry-run   Checks every prerequisite and builds nothing.
#   release-app.sh             Developer ID release: archive, export, verify, notarize,
#                              staple, DMG and update zip, Sparkle signature, appcast
#                              entry and cask. Output goes to app/build/release.
#   release-app.sh --local     Release build signed for this Mac, plus a DMG.
#                              No notarization, no appcast.
#   release-app.sh --update-cask <dmg> <version> [cask]
#                              Writes a DMG's version and checksum into the cask.
#
# Settings, all optional:
#   NOTARY_PROFILE   notarytool keychain profile name (default: earshot)
#   SPARKLE_ACCOUNT  keychain account of the Sparkle private key (default: ed25519)
#   RELEASE_NOTES    an HTML file shown in the update window and used for the GitHub release.
#                    Without it, the GitHub release notes list the commits under app/ since the
#                    previous app-v tag (written to app/build/release/release-notes.md).
#
# Versions, the team, the feed URL and the Sparkle public key are read from app/project.yml.
# The full release checks everything first and stops before building if anything is missing.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=$ROOT/app
SPEC=$APP/project.yml
OUT=$APP/build/release
PACKAGES=$APP/build/SourcePackages
SPARKLE_BIN=$PACKAGES/artifacts/sparkle/Sparkle/bin
APPCAST=$ROOT/packaging/appcast.xml
CASK=$ROOT/packaging/earshot.rb
PLUGIN_JSON=$ROOT/plugin/.claude-plugin/plugin.json
PLUGIN_LINK=$APP/EarshotKit/Sources/EarshotKit/Sessions/PluginLink.swift
REPO=sdusteric/earshot
BUNDLE_ID=com.earshot.app
TAG_PREFIX=app-v
FEED_URL_EXPECTED=https://raw.githubusercontent.com/$REPO/main/packaging/appcast.xml
KEY_PLACEHOLDER=SPARKLE_PUBLIC_KEY_NOT_SET
NOTARY_PROFILE=${NOTARY_PROFILE:-earshot}
SPARKLE_ACCOUNT=${SPARKLE_ACCOUNT:-ed25519}

fail() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

# update_cask <dmg> <version> [cask]: writes the release's version and checksum
# into the Homebrew cask, ready to copy to the tap.
update_cask() {
  local sum cask=${3:-$CASK}
  [ -f "$1" ] || fail "No such DMG: $1"
  sum=$(shasum -a 256 "$1" | cut -d' ' -f1)
  sed -i '' -e "s/^  version \".*\"/  version \"$2\"/" -e "s/^  sha256 .*/  sha256 \"$sum\"/" "$cask"
  echo "Cask: version $2, sha256 $sum"
}

# make_dmg <app> <dmg>: a disk image with the app and a link to Applications.
make_dmg() {
  local stage=$OUT/dmg
  rm -rf "$stage"; mkdir -p "$stage"
  cp -R "$1" "$stage/"; ln -s /Applications "$stage/Applications"
  if diskutil image create from --help >/dev/null 2>&1; then
    diskutil image create from --format UDZO --volumeName Earshot "$stage" "$2" >/dev/null 2>&1 \
      || fail "Couldn't make the disk image."
  else
    hdiutil create -volname Earshot -srcfolder "$stage" -ov -format UDZO "$2" >/dev/null \
      || fail "Couldn't make the disk image."
  fi
  rm -rf "$stage"
}

# yml <key>: the first value of <key> in project.yml, quoted or not.
yml() { sed -n -E "s/^ *$1: *\"?([^\"# ]*)\"? *(#.*)?$/\1/p" "$SPEC" | head -1; }

# version_ge <a> <b>: true when version a is b or newer.
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }

mode=release
case "${1:-}" in
  --update-cask) update_cask "${2:?dmg}" "${3:?version}" "${4:-}"; exit 0 ;;
  --local) mode=local ;;
  --dry-run|-n) mode=dry ;;
  "") ;;
  -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
  *) fail "Unknown option: $1 (try --help)" ;;
esac

ver=$(yml MARKETING_VERSION)
build=$(yml CURRENT_PROJECT_VERSION)
team=$(yml DEVELOPMENT_TEAM)
pubkey=$(yml SPARKLE_PUBLIC_KEY)
feed=$(yml SUFeedURL)
min_os=$(yml macOS)
tag=$TAG_PREFIX$ver

# --- Local build: this Mac only ---------------------------------------------

if [ "$mode" = local ]; then
  command -v xcodegen >/dev/null || fail "Needs XcodeGen: brew install xcodegen"
  rm -rf "$OUT"; mkdir -p "$OUT"
  xcodegen generate --spec "$SPEC" --project "$APP" >/dev/null
  step "Building Earshot $ver ($build) for this Mac"
  xcodebuild -project "$APP/Earshot.xcodeproj" -scheme Earshot -configuration Release \
    -derivedDataPath "$APP/build" build >"$OUT/build.log" 2>&1 || fail "Build failed: $OUT/build.log"
  cp -R "$APP/build/Build/Products/Release/Earshot.app" "$OUT/"
  codesign --verify --deep --strict "$OUT/Earshot.app" || fail "The app's signature does not verify."
  make_dmg "$OUT/Earshot.app" "$OUT/Earshot-$ver.dmg"
  echo "Built $OUT/Earshot-$ver.dmg"
  exit 0
fi

# --- Prerequisites -----------------------------------------------------------
# Every check runs, so one pass lists everything that is missing.

problems=0
ok() { echo "  ok       $*"; }
missing() { echo "  MISSING  $1"; shift; for line in "$@"; do echo "           $line"; done; problems=$((problems + 1)); }
note() { echo "  note     $*"; }

echo "Earshot for Mac release checks"
echo "  version  $ver, build $build, tag $tag, team $team"

[ -n "$team" ] || missing "DEVELOPMENT_TEAM is not set in app/project.yml." "Set it to the Apple team ID."
for tool in xcodebuild codesign spctl ditto hdiutil shasum xmllint plutil git; do
  command -v "$tool" >/dev/null || missing "$tool is not on PATH." "Install Xcode and its command line tools."
done
if command -v xcodegen >/dev/null; then ok "XcodeGen"; else missing "XcodeGen" "Run: brew install xcodegen"; fi
if xcrun --find notarytool >/dev/null 2>&1 && xcrun --find stapler >/dev/null 2>&1; then ok "notarytool and stapler"
else missing "notarytool or stapler" "Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app"; fi

# A release must come from a released Xcode. Builds from a beta or release candidate can be
# rejected by notarization or run differently from what people get.
xcode_path=$(xcode-select -p 2>/dev/null || true)
if echo "$xcode_path" | grep -Eiq 'beta|release[. ]candidate|[-. ]rc[0-9. -]|\.rc\.'; then
  missing "xcode-select points at a prerelease Xcode: $xcode_path" \
    "Release with a released Xcode: sudo xcode-select -s /Applications/Xcode.app"
else ok "Xcode: ${xcode_path%/Contents/Developer}"; fi

# Versions come from project.yml. Sparkle compares the build number, so it must grow.
if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ok "MARKETING_VERSION $ver"
else missing "MARKETING_VERSION in app/project.yml is '$ver'." "Use x.y.z, for example 0.1.0."; fi
last_build=0
if [ -f "$APPCAST" ]; then
  last_build=$(grep -o '<sparkle:version>[0-9]*</sparkle:version>' "$APPCAST" | grep -o '[0-9][0-9]*' | sort -n | tail -1 || true)
  last_build=${last_build:-0}
fi
if ! [[ "$build" =~ ^[0-9]+$ ]]; then
  missing "CURRENT_PROJECT_VERSION in app/project.yml is '$build'." "Use a whole number. Sparkle compares it to decide what is newer."
elif [ "$build" -le "$last_build" ]; then
  missing "CURRENT_PROJECT_VERSION $build is not newer than build $last_build in packaging/appcast.xml." \
    "Raise CURRENT_PROJECT_VERSION (and MARKETING_VERSION) in app/project.yml."
else ok "build $build is newer than the appcast's latest ($last_build)"; fi
if grep -q "<sparkle:shortVersionString>$ver</sparkle:shortVersionString>" "$APPCAST" 2>/dev/null; then
  missing "Version $ver is already in packaging/appcast.xml." "Raise MARKETING_VERSION in app/project.yml."
fi
# The tag is created on GitHub by gh release create, so a clone that has not fetched
# tags can look free here. Check the remote as well.
if git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  missing "Tag $tag already exists." "Raise MARKETING_VERSION in app/project.yml."
elif remote_tag=$(git -C "$ROOT" ls-remote --tags origin "refs/tags/$tag" 2>/dev/null); then
  if [ -n "$remote_tag" ]; then
    missing "Tag $tag already exists on origin." "Raise MARKETING_VERSION in app/project.yml, or run git fetch --tags."
  else ok "tag $tag is free (locally and on origin)"; fi
else
  note "could not reach origin to check for tag $tag. Check it by hand before publishing."
  ok "tag $tag is free locally"
fi

# The release is built from a clean, committed tree so the tag matches what shipped.
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
  missing "The working tree has uncommitted changes." "Commit or discard them first (git status)."
else ok "working tree is clean"; fi
branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)
[ "$branch" = main ] || note "building from branch '$branch', not main"

# Signing: a Developer ID Application certificate for the project's team.
id_line=$(security find-identity -v -p codesigning 2>/dev/null | grep "\"Developer ID Application: .*($team)\"" | head -1 || true)
identity_hash=$(echo "$id_line" | awk '{print $2}')
identity_name=$(echo "$id_line" | sed -n 's/.*"\(.*\)".*/\1/p')
if [ -n "$identity_hash" ]; then ok "certificate: $identity_name"
else missing "No \"Developer ID Application\" certificate for team $team in the keychain." \
  "Create one in Xcode > Settings > Accounts > Manage Certificates, or at developer.apple.com > Certificates." \
  "Only the Account Holder can create it."; fi
export_team=$(plutil -extract teamID raw -o - "$APP/ExportOptions.plist" 2>/dev/null || true)
[ "$export_team" = "$team" ] || missing "app/ExportOptions.plist has team '$export_team', project.yml has '$team'." "Make them match."
if grep -q get-task-allow "$APP/Earshot/Earshot.entitlements"; then
  missing "Earshot.entitlements has get-task-allow." "Remove it. Notarization rejects apps with it."
fi

# Notarization credentials stored in the keychain by notarytool.
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then ok "notarytool profile '$NOTARY_PROFILE'"
else missing "No working notarytool profile '$NOTARY_PROFILE'." \
  "Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <you@example.com> --team-id $team" \
  "It asks for an app-specific password from account.apple.com."; fi

# Sparkle: its tools come with the Swift package, the public key lives in project.yml,
# the private key in the login keychain.
if [ ! -x "$SPARKLE_BIN/sign_update" ] && command -v xcodegen >/dev/null; then
  echo "  ...      fetching Swift packages for Sparkle's tools"
  xcodegen generate --spec "$SPEC" --project "$APP" >/dev/null
  xcodebuild -resolvePackageDependencies -project "$APP/Earshot.xcodeproj" -scheme Earshot \
    -clonedSourcePackagesDirPath "$PACKAGES" >/dev/null 2>&1 || true
fi
if [ -x "$SPARKLE_BIN/sign_update" ] && [ -x "$SPARKLE_BIN/generate_keys" ]; then ok "Sparkle tools in app/build/SourcePackages"
else missing "Sparkle's sign_update and generate_keys." "Run: cd app && xcodegen generate && xcodebuild -resolvePackageDependencies -project Earshot.xcodeproj -scheme Earshot -clonedSourcePackagesDirPath build/SourcePackages"; fi
key_ok=
if [ -z "$pubkey" ] || [ "$pubkey" = "$KEY_PLACEHOLDER" ]; then
  missing "SPARKLE_PUBLIC_KEY in app/project.yml is the placeholder." \
    "Run app/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys once, then paste the public key it prints into SPARKLE_PUBLIC_KEY."
elif [ "$(printf '%s' "$pubkey" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" != 32 ]; then
  missing "SPARKLE_PUBLIC_KEY in app/project.yml is not a Sparkle EdDSA public key." "It is 44 characters of base64 from generate_keys."
else key_ok=1; ok "Sparkle public key in project.yml"; fi
if security find-generic-password -s "https://sparkle-project.org" -a "$SPARKLE_ACCOUNT" >/dev/null 2>&1; then
  if [ -n "$key_ok" ] && [ -x "$SPARKLE_BIN/generate_keys" ]; then
    keychain_pub=$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null || true)
    if [ "$keychain_pub" = "$pubkey" ]; then ok "Sparkle private key in the keychain matches project.yml"
    else missing "The Sparkle key in the keychain does not match SPARKLE_PUBLIC_KEY in project.yml." \
      "Updates signed with it would be rejected. Import the right key: generate_keys -f <exported-key-file>"; fi
  else ok "Sparkle private key in the keychain (account $SPARKLE_ACCOUNT)"; fi
else missing "No Sparkle private key in the login keychain (account $SPARKLE_ACCOUNT)." \
  "Run generate_keys once on this Mac, or import a saved key: generate_keys -f <exported-key-file>"; fi

# The feed: a file on main, so the plugin's GitHub releases cannot hide it.
if [ "$feed" = "$FEED_URL_EXPECTED" ]; then ok "feed URL $feed"
else missing "SUFeedURL in app/project.yml is '$feed'." "release-app.sh writes packaging/appcast.xml, served at $FEED_URL_EXPECTED"; fi
if [ -f "$APPCAST" ] && xmllint --noout "$APPCAST" 2>/dev/null; then ok "packaging/appcast.xml is valid XML"
else missing "packaging/appcast.xml is missing or not valid XML." "Restore it from git."; fi

# The app talks to the plugin and needs a recent enough one.
plugin_ver=$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$PLUGIN_JSON" | head -1)
plugin_min=$(sed -n 's/.*minimumVersion = "\([^"]*\)".*/\1/p' "$PLUGIN_LINK" | head -1)
if [ -n "$plugin_ver" ] && [ -n "$plugin_min" ] && version_ge "$plugin_ver" "$plugin_min"; then
  ok "plugin $plugin_ver meets the app's minimum $plugin_min"
  git -C "$ROOT" rev-parse -q --verify "refs/tags/v$plugin_ver" >/dev/null \
    || note "plugin $plugin_ver has no tag v$plugin_ver here. Release the plugin before the app."
else missing "plugin.json has version '$plugin_ver', the app needs $plugin_min or newer (PluginLink.minimumVersion)." \
  "Release a plugin that is new enough, or lower minimumVersion."; fi

if [ "$problems" -gt 0 ]; then
  echo "$problems thing(s) missing. Fix them and run this again. Nothing was built."
  exit 1
fi
if [ "$mode" = dry ]; then
  echo "Ready to release Earshot $ver ($build). Run scripts/release-app.sh without --dry-run."
  exit 0
fi
if [ -n "${RELEASE_NOTES:-}" ] && [ ! -f "$RELEASE_NOTES" ]; then fail "RELEASE_NOTES points to a missing file: $RELEASE_NOTES"; fi

# --- Build -------------------------------------------------------------------

rm -rf "$OUT"; mkdir -p "$OUT"
log=$OUT/build.log
app=$OUT/Earshot.app
commit=$(git -C "$ROOT" rev-parse HEAD)

step "Archiving Earshot $ver ($build)"
xcodegen generate --spec "$SPEC" --project "$APP" >/dev/null
xcodebuild -project "$APP/Earshot.xcodeproj" -scheme Earshot -configuration Release \
  -archivePath "$OUT/Earshot.xcarchive" -derivedDataPath "$APP/build/release-dd" \
  -clonedSourcePackagesDirPath "$PACKAGES" archive >"$log" 2>&1 || fail "Archive failed. See $log"

step "Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$OUT/Earshot.xcarchive" -exportOptionsPlist "$APP/ExportOptions.plist" \
  -exportPath "$OUT/export" >>"$log" 2>&1 || fail "Export failed. See $log"
mv "$OUT/export/Earshot.app" "$app"

step "Checking the signature, hardened runtime and entitlements"
codesign --verify --deep --strict --verbose=2 "$app" >>"$log" 2>&1 || fail "codesign --verify --deep --strict failed. See $log"
info=$app/Contents/Info.plist
plist() { plutil -extract "$1" raw -o - "$info" 2>/dev/null || true; }
[ "$(plist CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "Bundle ID is $(plist CFBundleIdentifier), expected $BUNDLE_ID."
[ "$(plist CFBundleShortVersionString)" = "$ver" ] || fail "The app says version $(plist CFBundleShortVersionString), project.yml says $ver."
[ "$(plist CFBundleVersion)" = "$build" ] || fail "The app says build $(plist CFBundleVersion), project.yml says $build."
[ "$(plist SUPublicEDKey)" = "$pubkey" ] || fail "The app's SUPublicEDKey does not match project.yml."
[ "$(plist SUFeedURL)" = "$feed" ] || fail "The app's SUFeedURL does not match project.yml."
# Every piece of code inside, Sparkle's helpers included, needs a Developer ID
# signature, the hardened runtime and a secure timestamp, or notarization fails.
check_code() {
  local d
  d=$(codesign -dvvv "$1" 2>&1) || fail "Not signed: $1"
  echo "$d" | grep -q "^Authority=Developer ID Application: " || fail "Not signed with Developer ID: $1"
  echo "$d" | grep -q "^Timestamp=" || fail "No secure timestamp: $1"
  echo "$d" | grep -Eq "^CodeDirectory .*flags=.*runtime" || fail "No hardened runtime: $1"
  echo "$d" | grep -q "^TeamIdentifier=$team" || echo "note: signed by another team: ${1#"$app"/}"
}
check_code "$app"
codesign -dvvv "$app" 2>&1 | grep -q "^TeamIdentifier=$team$" || fail "The app is not signed by team $team."
while IFS= read -r nested; do check_code "$nested"; done < <(
  find "$app/Contents" -type d \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' \)
  find "$app/Contents" -type f \( -name '*.dylib' -o -path '*Sparkle.framework/Versions/*/Autoupdate' \)
)
ents=$(codesign -d --entitlements - --xml "$app" 2>/dev/null | tr -d ' \t\n')
echo "$ents" | grep -q '<key>com.apple.security.device.audio-input</key><true/>' || fail "The signed app lacks the audio-input entitlement."
if echo "$ents" | grep -q get-task-allow; then fail "The signed app has get-task-allow. It would fail notarization."; fi
echo "Signature, runtime and entitlements OK"

# notarize <file> <label>: submits, waits and stops unless Apple accepts it.
notarize() {
  local json=$OUT/notary-$2.json status id
  step "Notarizing the $2 (this takes a few minutes)"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json \
    2>>"$log" | grep '^{' | tail -1 >"$json" || true
  status=$(plutil -extract status raw -o - "$json" 2>/dev/null || true)
  id=$(plutil -extract id raw -o - "$json" 2>/dev/null || true)
  if [ "$status" != Accepted ]; then
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" "$OUT/notary-$2-log.json" >/dev/null 2>&1 || true
    fail "Notarization of the $2 ended with status '${status:-unknown}'. See $json, $OUT/notary-$2-log.json and $log"
  fi
  echo "Accepted ($id)"
}

ditto -c -k --keepParent "$app" "$OUT/notarize.zip"
notarize "$OUT/notarize.zip" app
rm -f "$OUT/notarize.zip"
xcrun stapler staple "$app" >>"$log" 2>&1 || fail "Stapling the app failed. See $log"
xcrun stapler validate "$app" >>"$log" 2>&1 || fail "The app's staple does not validate."
gk=$(spctl --assess --type execute --verbose=2 "$app" 2>&1 || true); echo "$gk" >>"$log"
case "$gk" in *"source=Notarized Developer ID"*) ;; *) fail "Gatekeeper does not accept the app: $gk" ;; esac
codesign --verify --deep --strict "$app" || fail "The stapled app's signature does not verify."
echo "Gatekeeper accepts the app"

# Sparkle installs from a zip of the stapled app.
zip=$OUT/Earshot-$ver.zip
step "Making $zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

# The DMG holds the app and a link to Applications, for people and for Homebrew.
dmg=$OUT/Earshot-$ver.dmg
step "Making $dmg"
make_dmg "$app" "$dmg"
codesign --sign "$identity_hash" --timestamp "$dmg" >>"$log" 2>&1 || fail "Signing the DMG failed. See $log"
notarize "$dmg" dmg
xcrun stapler staple "$dmg" >>"$log" 2>&1 || fail "Stapling the DMG failed. See $log"
gk=$(spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg" 2>&1 || true); echo "$gk" >>"$log"
case "$gk" in *"source=Notarized Developer ID"*) ;; *) fail "Gatekeeper does not accept the DMG: $gk" ;; esac
echo "Gatekeeper accepts the DMG"

step "Signing the update for Sparkle"
attrs=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$zip") || fail "sign_update failed."
sig=$(echo "$attrs" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
len=$(echo "$attrs" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')
[ -n "$sig" ] && [ -n "$len" ] || fail "Unexpected sign_update output: $attrs"
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$zip" "$sig" >/dev/null 2>&1 \
  || fail "The update's signature does not verify."
echo "EdDSA signature OK"

step "Adding $ver to packaging/appcast.xml"
base=https://github.com/$REPO/releases/download/$tag
item=$OUT/appcast-item.xml
{
  echo "    <item>"
  echo "      <title>Version $ver</title>"
  echo "      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>"
  echo "      <sparkle:version>$build</sparkle:version>"
  echo "      <sparkle:shortVersionString>$ver</sparkle:shortVersionString>"
  echo "      <sparkle:minimumSystemVersion>$min_os</sparkle:minimumSystemVersion>"
  echo "      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$tag</sparkle:fullReleaseNotesLink>"
  if [ -n "${RELEASE_NOTES:-}" ]; then
    echo "      <description><![CDATA["; cat "$RELEASE_NOTES"; echo "      ]]></description>"
  fi
  echo "      <enclosure url=\"$base/Earshot-$ver.zip\" type=\"application/octet-stream\" $attrs/>"
  echo "    </item>"
} >"$item"
cp "$APPCAST" "$OUT/appcast.before.xml"
awk -v item="$item" '{ print } /release-app.sh adds each release below this line/ { while ((getline l < item) > 0) print l }' \
  "$OUT/appcast.before.xml" >"$APPCAST"
grep -q "<sparkle:version>$build</sparkle:version>" "$APPCAST" || { cp "$OUT/appcast.before.xml" "$APPCAST"; fail "The appcast has no marker line, so the entry was not added."; }
xmllint --noout "$APPCAST" || { cp "$OUT/appcast.before.xml" "$APPCAST"; fail "The new appcast is not valid XML. It was restored."; }
cp "$APPCAST" "$OUT/appcast.xml"

update_cask "$dmg" "$ver"
(cd "$OUT" && shasum -a 256 "Earshot-$ver.dmg" "Earshot-$ver.zip" >SHA256SUMS)
printf 'version %s\nbuild %s\ncommit %s\nidentity %s\n' "$ver" "$build" "$commit" "$identity_name" >"$OUT/release-info.txt"

# GitHub's --generate-notes lists every commit since the last release, and the last release
# is usually a plugin one. Without RELEASE_NOTES, list the commits that touched app/ since
# the previous app release tag instead.
notes_file=${RELEASE_NOTES:-}
if [ -z "$notes_file" ]; then
  notes_file=$OUT/release-notes.md
  prev_tag=$(git -C "$ROOT" tag --list "${TAG_PREFIX}*" --sort=-v:refname | head -1)
  range=HEAD; [ -n "$prev_tag" ] && range="$prev_tag..HEAD"
  {
    echo "Changes to Earshot for Mac${prev_tag:+ since ${prev_tag#"$TAG_PREFIX"}}:"
    echo
    git -C "$ROOT" log --no-merges --format='- %s' "$range" -- app | grep -v 'Package.resolved' || true
  } >"$notes_file"
  note "release notes written from git history to $notes_file. Edit them before publishing."
fi
cat <<EOF

Built and notarized Earshot $ver ($build) from $commit:
  $dmg
  $zip
  $OUT/SHA256SUMS
packaging/appcast.xml and packaging/earshot.rb are updated but not committed.

Publish, in this order (the feed goes live last, once the files exist):
  git push origin $branch
  gh release create $tag "$dmg" "$zip" --repo $REPO --target $commit \\
    --title "Earshot for Mac $ver" --latest=false --notes-file "$notes_file"
  git add packaging/appcast.xml packaging/earshot.rb
  git commit -m "Earshot for Mac $ver: appcast and cask"
  git push origin $branch
Then copy packaging/earshot.rb to Casks/earshot.rb in $REPO's tap (sdusteric/homebrew-earshot) and push it.
EOF

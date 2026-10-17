# Releasing Kobi for Mac

This is the checklist for a signed, notarized release of Kobi for Mac that updates
itself with Sparkle. Steps 1 to 3 happen once per Mac. Steps 4 to 8 happen for every release.

`scripts/release-app.sh` does the build work. It checks every prerequisite first and
stops before building if anything is missing, so a failed check never leaves a half
finished release.

## What you need

- A paid Apple Developer Program membership for team `8N9KUZLT8N`, signed in to Xcode.
- A released Xcode (not a beta or release candidate) and XcodeGen (`brew install xcodegen`).
  Build releases only with a released Xcode: run `xcode-select -p` and check that it points
  at a normal `Xcode.app`. The script refuses a path that says beta or release candidate. To
  switch: `sudo xcode-select -s /Applications/Xcode.app`.
- The GitHub CLI, signed in to an account that can push to `sdusteric/earshot` (`gh auth status`).

## Once per Mac

### 1. Get a Developer ID Application certificate

Only the team's Account Holder can create one.

1. Open Xcode > Settings > Accounts, pick the team, and click Manage Certificates.
2. Click +, then Developer ID Application.
3. Check that it is in the keychain: `security find-identity -v -p codesigning`.
   A line should read `Developer ID Application: <name> (8N9KUZLT8N)`.

You can also create it at developer.apple.com > Certificates. Then download it and
double click it to add it to the login keychain.

To release from another Mac, export the certificate with its private key from
Keychain Access as a .p12 file and import it there.

### 2. Store notarization credentials

1. Create an app-specific password at account.apple.com > Sign-In and Security >
   App-Specific Passwords.
2. Store it in the keychain under the profile name `kobi`:

   ```
   xcrun notarytool store-credentials kobi --apple-id <your Apple ID> --team-id 8N9KUZLT8N
   ```

   It asks for the app-specific password.

An App Store Connect API key works too:
`xcrun notarytool store-credentials kobi --key AuthKey_XXXX.p8 --key-id <id> --issuer <issuer id>`.

To use another profile name, set `NOTARY_PROFILE=<name>` when you run the script.

### 3. Make the Sparkle signing keys

Sparkle only installs an update whose EdDSA signature matches the public key inside
the app. Make the keys once and keep the private key safe.

1. Fetch Sparkle's tools, which come with the Swift package:

   ```
   cd app && xcodegen generate && xcodebuild -resolvePackageDependencies \
     -project Kobi.xcodeproj -scheme Kobi -clonedSourcePackagesDirPath build/SourcePackages
   ```

2. Run `app/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`.
   It saves the private key in the login keychain and prints the public key.
3. In `app/project.yml`, replace `SPARKLE_PUBLIC_KEY_NOT_SET` with the public key
   (44 characters of base64). Commit the change. The public key is safe to publish.
4. Back up the private key: `generate_keys -x ~/Desktop/kobi-sparkle-key`, move
   the file into a password manager, and delete it. Never commit it.
   To use the key on another Mac, run `generate_keys -f <file>` there.

If the private key is lost, installed copies can never update again. Their users
would have to download a new version by hand.

Until step 3 is done, builds leave the updater off: `Updater.swift` only starts
Sparkle when `SUPublicEDKey` holds a real key.

## Every release

### 4. Set the version

In `app/project.yml`:

- `MARKETING_VERSION` is the version people see, for example `0.2.0`.
- `CURRENT_PROJECT_VERSION` is the build number. Sparkle compares it to decide what
  is newer, so it must go up by at least one for every release.

Commit the change. The script refuses to run on a tree with uncommitted changes.

### 5. Run the dry run

```
bash scripts/release-app.sh --dry-run
```

It checks, without building: XcodeGen and Xcode's tools, that Xcode is not a beta or
release candidate, the version and build number against `packaging/appcast.xml`, the
local git tags and the tags on `origin` (it only notes a problem if `origin` is
unreachable), a clean tree, the
Developer ID certificate, the notarytool profile, Sparkle's tools and both keys (and
that they match), the feed URL, and the plugin version. Each missing item comes with
the command that fixes it. It exits with status 0 only when everything is ready.

### 6. Run the release

```
bash scripts/release-app.sh
```

To show release notes in the update window, write them as HTML and run
`RELEASE_NOTES=notes.html bash scripts/release-app.sh`. The same file becomes the
GitHub release notes.

Without `RELEASE_NOTES`, the script writes `app/build/release/release-notes.md` from the
commits that touched `app/` since the previous `app-v` tag, and uses that for the GitHub
release. It does not use GitHub's generated notes, because those include plugin commits.
The update window shows no notes in that case. Read the file and edit it before you publish.

The script then:

1. Archives the Release build and exports it with the Developer ID certificate.
2. Checks the app and everything inside it, Sparkle's helpers included: a valid
   signature (`codesign --verify --deep --strict`), Developer ID, hardened runtime,
   secure timestamp, the microphone entitlement, no `get-task-allow`, and that the
   version, build, feed URL and public key in Info.plist match `project.yml`.
3. Notarizes the app with `xcrun notarytool submit --keychain-profile kobi --wait`,
   staples the ticket, and checks it with `spctl`.
4. Makes `Kobi-<version>.zip` for Sparkle and `Kobi-<version>.dmg` for people
   and Homebrew. It signs, notarizes and staples the DMG too.
5. Signs the zip with Sparkle's `sign_update` and verifies the signature.
6. Adds an item for this release to `packaging/appcast.xml` and writes the DMG's
   version and checksum into `packaging/kobi.rb`.

Everything lands in `app/build/release`. If notarization fails, Apple's log is saved
next to it as `notary-app-log.json` or `notary-dmg-log.json`.

### 7. Publish the GitHub release and the appcast

The script prints these commands with the values filled in. Run them in this order,
so the feed only goes live once the files it points to exist:

```
git push origin main
gh release create app-v<version> app/build/release/Kobi-<version>.dmg \
  app/build/release/Kobi-<version>.zip --repo sdusteric/earshot --target <commit> \
  --title "Kobi for Mac <version>" --latest=false --notes-file app/build/release/release-notes.md
git add packaging/appcast.xml packaging/kobi.rb
git commit -m "Kobi for Mac <version>: appcast and cask"
git push origin main
```

App releases use tags `app-v<version>`. Plugin releases use `v<version>`.

#### Where the feed lives

The app reads its updates from
`https://raw.githubusercontent.com/sdusteric/earshot/main/packaging/appcast.xml`
(`SUFeedURL` in `app/project.yml`). The feed is a file on `main` and not a release
asset: the plugin's releases are marked Latest on GitHub, so a
`releases/latest/download/appcast.xml` URL would point at a plugin release that has
no appcast. The app's releases are made with `--latest=false` for the same reason.
GitHub can take up to five minutes to serve a new version of the file.

The feed URL is built into every copy of the app, so do not move the file. If it
ever has to move, ship one release that points at the new place and keep the old
file updated until most people have that release.

### 8. Update the Homebrew cask

The tap is a separate repo, `sdusteric/homebrew-kobi`, with the cask at
`Casks/kobi.rb`. Create it once with `gh repo create sdusteric/homebrew-kobi --public`.

1. Copy `packaging/kobi.rb` (now with the new version and sha256) to
   `Casks/kobi.rb` in the tap, commit, and push.
2. Check it: `brew tap sdusteric/kobi`, then
   `brew audit --cask --new --online sdusteric/kobi/kobi` for the first version
   (`--online` alone for later ones), then `brew install --cask sdusteric/kobi/kobi`.

The cask quits the app on uninstall (`uninstall quit`). `brew uninstall --zap` also removes the
app's own files and the listening models in `~/Library/Application Support/FluidAudio`. It
leaves `~/.cache/fluidaudio` (the Kokoro voice) and `~/.config/kobi` (settings and the
ElevenLabs key) because the plugin uses them too.

People install it with `brew install --cask sdusteric/kobi/kobi`. The cask
says `auto_updates true`, so Sparkle updates it and `brew upgrade` leaves it alone.

To fill in a cask by hand: `bash scripts/release-app.sh --update-cask <dmg> <version>`.

## Files that ship with the app

- `THIRD_PARTY_NOTICES.md` at the repo root is copied into the app's Resources by
  `app/project.yml`. When you change the Sparkle or FluidAudio version, or the models the
  app downloads, update that file and check each license again.
- `app/project.yml` holds the usage strings macOS shows when Kobi first opens a project
  in Documents, Desktop, Downloads, or on an external or network volume.
- `app/KobiKit/Package.resolved` lists Sparkle as well as FluidAudio. Xcode writes the
  app's Sparkle pin into this file, so `Package.swift` declares the same Sparkle version to
  make `swift package resolve` write the same result. When you change the Sparkle version in
  `app/project.yml`, change it in `app/KobiKit/Package.swift` too and commit the updated
  `Package.resolved`. If the file shows as modified before a release, a version differs.
- The app is Apple Silicon only (decided 2026-10-13): `project.yml` sets `ARCHS: arm64` and the
  cask says `depends_on arch: :arm64`. The plugin's Kokoro build refuses Intel, and nobody has
  tested the app's voice or listening models on an Intel Mac.

## The plugin and the app

The app talks to the Claude Code plugin and needs plugin `0.12.0` or newer (the first named kobi). The
minimum is `PluginLink.minimumVersion` in
`app/KobiKit/Sources/KobiKit/Sessions/PluginLink.swift`. People get the plugin
from this repo's marketplace (`sdusteric/earshot`), and the app offers an update when
theirs is older.

- Release the plugin first (bump `plugin/.claude-plugin/plugin.json`, tag `v<version>`),
  then the app.
- When an app release depends on new plugin behavior, raise `minimumVersion` in the
  same change and release that plugin version before the app.
- The dry run fails when `plugin.json` is older than `minimumVersion`, and notes it
  when the plugin version has no `v<version>` tag yet.

## After the release

- Download the DMG from the GitHub release on another Mac or another user account,
  open it, and drag the app to Applications. It should open without a Gatekeeper warning.
- With the previous version installed, choose Check for Updates in the menu. It should
  offer the new version and install it.
- `spctl --assess --type execute -vv /Applications/Kobi.app` should print
  `source=Notarized Developer ID`.

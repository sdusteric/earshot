# Homebrew cask for Kobi for Mac. It lives in the tap repo sdusteric/homebrew-kobi
# as Casks/kobi.rb. scripts/release-app.sh writes version and sha256 here for each
# release. Copy the file to the tap after the GitHub release is published.
# Until the first release, sha256 holds a placeholder and the cask cannot install.
cask "kobi" do
  version "0.1.0"
  sha256 "REPLACE_WITH_DMG_SHA256_FROM_RELEASE_APP_SH"

  url "https://github.com/sdusteric/earshot/releases/download/app-v#{version}/Kobi-#{version}.dmg"
  name "Kobi"
  desc "Voice companion for Claude Code sessions"
  homepage "https://github.com/sdusteric/earshot"

  livecheck do
    url "https://raw.githubusercontent.com/sdusteric/earshot/main/packaging/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "Kobi.app"

  uninstall quit: "com.kobi.app"

  # Left out on purpose: ~/.cache/fluidaudio (the Kokoro voice) and ~/.config/kobi
  # (settings and the ElevenLabs key). The Kobi plugin uses both, so removing them
  # would break plugin-only use.
  zap trash: [
    "~/Library/Application Support/Kobi",
    "~/Library/Application Support/FluidAudio",
    "~/Library/Saved Application State/com.kobi.app.savedState",
    "~/Library/Caches/com.kobi.app",
    "~/Library/HTTPStorages/com.kobi.app",
    "~/Library/Preferences/com.kobi.app.plist",
  ]
end

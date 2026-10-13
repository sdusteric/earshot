# Homebrew cask for Earshot for Mac. It lives in the tap repo sdusteric/homebrew-earshot
# as Casks/earshot.rb. scripts/release-app.sh writes version and sha256 here for each
# release. Copy the file to the tap after the GitHub release is published.
# Until the first release, sha256 holds a placeholder and the cask cannot install.
cask "earshot" do
  version "0.1.0"
  sha256 "REPLACE_WITH_DMG_SHA256_FROM_RELEASE_APP_SH"

  url "https://github.com/sdusteric/earshot/releases/download/app-v#{version}/Earshot-#{version}.dmg"
  name "Earshot"
  desc "Voice notifications for Claude Code"
  homepage "https://github.com/sdusteric/earshot"

  livecheck do
    url "https://raw.githubusercontent.com/sdusteric/earshot/main/packaging/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: ">= :tahoe"

  app "Earshot.app"

  zap trash: [
    "~/Library/Application Support/Earshot",
    "~/Library/Caches/com.earshot.app",
    "~/Library/HTTPStorages/com.earshot.app",
    "~/Library/Preferences/com.earshot.app.plist",
  ]
end

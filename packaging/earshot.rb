# Homebrew cask for Earshot for Mac. Lives in a tap repo (sdusteric/homebrew-earshot)
# as Casks/earshot.rb. Update version and sha256 for each release.
cask "earshot" do
  version "0.1.0"
  sha256 :no_check

  url "https://github.com/sdusteric/earshot/releases/download/app-v#{version}/Earshot-#{version}.dmg"
  name "Earshot"
  desc "Voice notifications for Claude Code"
  homepage "https://github.com/sdusteric/earshot"

  depends_on macos: ">= :tahoe"
  auto_updates true

  app "Earshot.app"

  zap trash: [
    "~/Library/Application Support/Earshot",
    "~/Library/Preferences/com.earshot.app.plist",
  ]
end

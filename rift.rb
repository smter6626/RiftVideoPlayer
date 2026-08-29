cask "rift" do
  version "1.0.0-dev.62"
  sha256 "aa981b625b4698395507d0b51b154199ff1e699caed31e0e18a3727b475aad86"

  url "https://github.com/rafaelo96/RiftVideoPlayer/releases/download/v#{version}/Rift.dmg"
  name "Rift"
  desc "Native video player with Frame⁺ AI interpolation, HDR support, and Metal-accelerated rendering"
  homepage "https://github.com/rafaelo96/RiftVideoPlayer"

  auto_updates false

  app "Rift.app"

  postflight do
    system_command "xattr",
                   args: ["-cr", "#{appdir}/Rift.app"]
  end

  zap trash: [
    "~/Library/Application Support/Rift",
    "~/Library/Caches/Rift",
    "~/Library/Preferences/com.rift.player.plist",
  ]
end

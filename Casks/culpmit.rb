cask "culpmit" do
  version "1.0.3"
  sha256 "3a408218c49abd5c05cc39389da38402393bf497633aa8f73f8ba74548a8bdea"

  url "https://github.com/booban1/culpmit/releases/download/v#{version}/Culpmit-#{version}.zip"
  name "Culpmit"
  desc "Culprit Limiter: names the apps heating an Intel Mac and holds them to a share of the CPU"
  homepage "https://github.com/booban1/culpmit"

  depends_on macos: ">= :ventura"
  depends_on arch: :x86_64

  app "Culpmit.app"

  uninstall launchctl: "com.simonbooban.culpmit",
            quit:      "com.simonbooban.culpmit"

  zap trash: [
    "~/Library/LaunchAgents/com.simonbooban.culpmit.plist",
    "~/Library/Application Support/Culpmit",
    "~/Library/Logs/Culpmit figma-socket.log",
    "~/Library/Logs/Culpmit.log",
    "~/Library/Preferences/com.simonbooban.culpmit.plist",
  ]
end

cask "culpmit" do
  version "1.0.0"
  sha256 "989cd1da5b7a71928b1e3a0dc85660a4fd42c469810f395c1921038c509bfd34"

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

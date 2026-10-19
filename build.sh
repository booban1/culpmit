#!/bin/zsh
# Builds Culpmit.app for Intel Macs; "./build.sh install" puts it in Applications and opens it,
# "./build.sh release" zips it for a GitHub release
set -e
cd "${0:A:h}"

name="Culpmit"
app="build.noindex/$name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

swiftc -O -target x86_64-apple-macos13.0 Sources/**/*.swift -o "$app/Contents/MacOS/$name"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
commit=$(git rev-parse --short HEAD 2>/dev/null || echo dev)
count=$(git rev-list --count HEAD 2>/dev/null || echo 0)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $count" -c "Add :CulpmitCommit string $commit" "$app/Contents/Info.plist"
# uncommitted changes run ahead of the latest release, so this build keeps its Update row hidden
if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
  /usr/libexec/PlistBuddy -c "Add :CulpmitLocal bool true" "$app/Contents/Info.plist"
fi
# the seven test apps behind Test load: one small binary in seven bundles, each with its own name and icon
swiftc -O -target x86_64-apple-macos13.0 TestLoad/Load.swift -o build.noindex/Load
for i in {1..7}; do
  helper="$app/Contents/Helpers/Test Load $i.app"
  mkdir -p "$helper/Contents/MacOS" "$helper/Contents/Resources"
  cp build.noindex/Load "$helper/Contents/MacOS/Load"
  sed "s/NUMBER/$i/g" TestLoad/Info.plist > "$helper/Contents/Info.plist"
  cp "TestLoad/Load $i.icns" "$helper/Contents/Resources/Load.icns"
done
# one lasting signature keeps macOS permissions across builds and updates; ad hoc where the certificate is absent.
# The self-signed certificate needs zero trust settings: its hash alone fixes the app's identity.
# The test apps are signed first, as the app's own signature covers them.
identity=$(security find-identity -p codesigning 2>/dev/null | awk '/"Culpmit Signer"/ { print $2; exit }')
for helper in "$app/Contents/Helpers/"*.app; do codesign --force --sign "${identity:--}" "$helper"; done
codesign --force --sign "${identity:--}" "$app"
echo "Built $app"

if [[ $1 == install ]]; then
  pkill -a -x "$name" || true
  for i in {1..50}; do pgrep -a -qx "$name" || break; sleep 0.1; done
  ditto "$app" "/Applications/$name.app"
  # a fresh date and registration let the launcher and Finder pick up a new icon
  touch "/Applications/$name.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$name.app"
  open "/Applications/$name.app" || { sleep 1; open "/Applications/$name.app"; }
  echo "Installed /Applications/$name.app"
fi

if [[ $1 == release ]]; then
  version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
  zip="build.noindex/$name-$version.zip"
  rm -f "$zip"
  ditto -c -k --keepParent --norsrc --noextattr --noacl "$app" "$zip"
  shasum -a 256 "$zip" | cut -d' ' -f1 > "$zip.sha256"
  echo "Zipped $zip"
fi

#!/bin/zsh
# Builds Culpmit for Windows on the Mac: build.noindex/Culpmit.exe from the .NET SDK and .NET Framework 4.8's reference
# assemblies. "./build.sh test" runs the core's checks on the Mac first; "./build.sh release" also zips the exe as
# Culpmit-<version>-windows.zip with its .sha256, the names the Windows updater and the site's download look for.
set -e
cd "${0:A:h}"
export PATH="/usr/local/share/dotnet:$PATH" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

if [[ $1 == test || $1 == release ]]; then
  dotnet run --project Tests/Tests.csproj -c Release -f net11.0
fi

dotnet build Culpmit.csproj -c Release -nologo -v quiet
cp build.noindex/bin/Culpmit/Release/Culpmit.exe build.noindex/Culpmit.exe
echo "Built windows/build.noindex/Culpmit.exe"

if [[ $1 == release ]]; then
  version=$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' Culpmit.csproj)
  zip="build.noindex/Culpmit-$version-windows.zip"
  rm -f "$zip" "$zip.sha256"
  (cd build.noindex && zip -q -X "Culpmit-$version-windows.zip" Culpmit.exe)
  (cd build.noindex && shasum -a 256 "Culpmit-$version-windows.zip" > "Culpmit-$version-windows.zip.sha256")
  echo "Zipped $zip"
fi

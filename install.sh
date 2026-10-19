#!/bin/bash
# Installs the latest Culpmit release into Applications and opens it
set -euo pipefail

if [[ $(uname -m) != x86_64 ]]; then
  echo "Culpmit is built for Intel Macs. Apple silicon support comes in a later version."
  exit 1
fi

url=$(curl -fsSL https://api.github.com/repos/booban1/culpmit/releases/latest \
  | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | cut -d'"' -f4)
if [[ -z $url ]]; then
  echo "GitHub is out of reach right now. Try again in a moment."
  exit 1
fi

dir=$(mktemp -d)
echo "Downloading ${url##*/}"
curl -fsSL "$url" -o "$dir/culpmit.zip"
ditto -x -k "$dir/culpmit.zip" "$dir"

pkill -x Culpmit 2>/dev/null && sleep 1 || true
ditto "$dir/Culpmit.app" /Applications/Culpmit.app
open /Applications/Culpmit.app
echo "Culpmit is in Applications and running in the menu bar."

#!/bin/zsh
# Builds a Release copy of Stitch and installs it in /Applications (needed for "Open at login").
# Usage: scripts/install.sh
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate >/dev/null
xcodebuild -scheme Stitch -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
pkill -x Stitch 2>/dev/null || true
rm -rf /Applications/Stitch.app
cp -R build/DerivedData/Build/Products/Release/Stitch.app /Applications/
open /Applications/Stitch.app
echo "Installed /Applications/Stitch.app"

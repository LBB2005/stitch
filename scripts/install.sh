#!/bin/zsh
# Builds a Release copy of Stitch and installs it in /Applications (needed for "Open at login").
# Usage: scripts/install.sh
set -euo pipefail
cd "${0:A:h}/.."
scripts/build-mupdf.sh || exit 1
xcodegen generate >/dev/null
xcodebuild -scheme Stitch -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
pkill -x Stitch 2>/dev/null || true
rm -rf /Applications/Stitch.app
cp -R build/DerivedData/Build/Products/Release/Stitch.app /Applications/
# The installed copy must run hardened and refuse debugger attach (see docs/audits/SECURITY-AUDIT.md, M1).
# Read codesign's output first: with pipefail, grep -q closing the pipe early would count as a failure.
sig=$(codesign -dvv /Applications/Stitch.app 2>&1 || true)
ents=$(codesign -d --entitlements - /Applications/Stitch.app 2>/dev/null || true)
if [[ "$sig" != *runtime* || "$ents" == *get-task-allow* ]]; then
  echo "warning: /Applications/Stitch.app is not hardened (runtime off or get-task-allow present)" >&2
fi
# Right after the old copy quits, Launch Services can refuse the first open (-600); try again.
open /Applications/Stitch.app 2>/dev/null || { sleep 2; open /Applications/Stitch.app; }
echo "Installed /Applications/Stitch.app"

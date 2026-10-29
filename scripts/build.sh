#!/bin/zsh
# Regenerates the project and builds the Debug app.
set -o pipefail
cd "${0:A:h}/.."
xcodegen generate >/dev/null || exit 1
xcodebuild -scheme Stitch -destination 'platform=macOS' -derivedDataPath build/DerivedData build 2>&1 \
  | grep -E "error:|warning: .*\.swift|BUILD (SUCCEEDED|FAILED)" | awk '!seen[$0]++'

#!/bin/zsh
# Debug build: a Stitch window draws itself into a PNG (no Screen Recording permission needed).
# Usage: scripts/winshot.sh <app|document|form|appsettings> [light|dark] [out.png]
set -euo pipefail
cd "${0:A:h}/.."
screen=${1:-app}; mode=${2:-light}; out=${3:-build/shots/$screen-$mode.png}
mkdir -p "${out:h}"
pkill -x Stitch 2>/dev/null || true
sleep 1
rm -f "$out"
open -W build/DerivedData/Build/Products/Debug/Stitch.app --args -StitchDemo "$screen" -StitchDemoAppearance "$mode" -StitchDemoSnapshot "$PWD/$out"
echo "$out"

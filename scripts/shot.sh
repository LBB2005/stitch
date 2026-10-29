#!/bin/zsh
# Debug-build screenshots of each panel screen: scripts/shot.sh <screen> [light|dark] [out.png]
# Screens: empty, drop, files, arrange, done, settings. Needs Screen Recording permission for the terminal.
set -euo pipefail
cd "${0:A:h}/.."
screen=${1:-files}; mode=${2:-light}; out=${3:-build/shots/$screen-$mode.png}
mkdir -p "${out:h}"
app=build/DerivedData/Build/Products/Debug/Stitch.app
pkill -x Stitch 2>/dev/null || true
sleep 1.5
open "$app" --args -StitchDemo "$screen" -StitchDemoAppearance "$mode"
sleep ${SHOT_DELAY:-3}
id=""
for _ in 1 2 3 4 5; do
  id=$(swift -e 'import CoreGraphics; let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]; for w in l where (w["kCGWindowOwnerName"] as? String) == "Stitch" && (w["kCGWindowLayer"] as? Int ?? 0) > 20 { print(w["kCGWindowNumber"]!); break }')
  [[ -n $id ]] && break
  sleep 1
done
screencapture -o -l"$id" "$out"
echo "$out"

#!/bin/bash
# Renders scripts/icon.html to assets/icon.png (1024px) and assets/AppIcon.icns. Needs Google Chrome.
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$CHROME" --headless=new --user-data-dir="$TMP/profile" --hide-scrollbars --force-device-scale-factor=1 \
  --default-background-color=00000000 --window-size=1024,1024 \
  --screenshot="$PWD/assets/icon.png" "file://$PWD/scripts/icon.html" 2>/dev/null
mkdir -p "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon.png --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) assets/icon.png --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o assets/AppIcon.icns
echo "wrote assets/icon.png and assets/AppIcon.icns"

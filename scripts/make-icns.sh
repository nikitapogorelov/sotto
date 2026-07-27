#!/usr/bin/env bash
# Generates Sotto.icns from assets/appicon.svg.
# Requires librsvg: brew install librsvg
set -euo pipefail
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || { echo "brew install librsvg first"; exit 1; }

ICONSET=build/Sotto.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" assets/appicon.svg -o "$ICONSET/icon_${size}x${size}.png"
  rsvg-convert -w "$((size*2))" -h "$((size*2))" assets/appicon.svg -o "$ICONSET/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$ICONSET" -o Resources/Sotto.icns
echo "Wrote Resources/Sotto.icns"

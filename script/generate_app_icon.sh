#!/usr/bin/env bash
# Produce the ten standard macOS icon representations from the unchanged master PNG.
set -euo pipefail
HIDAN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDAN_BRAND_DIR="$HIDAN_ROOT/Sources/HidanClub/Resources/Brand"
HIDAN_LOGO="$HIDAN_BRAND_DIR/HidanLogo.png"
HIDAN_ICON="$HIDAN_BRAND_DIR/AppIcon.icns"
HIDAN_ICON_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hidan-icon.XXXXXX")"
trap 'rm -rf "$HIDAN_ICON_TMP"' EXIT
HIDAN_ICONSET="$HIDAN_ICON_TMP/AppIcon.iconset"
mkdir -p "$HIDAN_ICONSET"
test -f "$HIDAN_LOGO"
for HIDAN_SIZE in 16 32 128 256 512; do
  /usr/bin/sips -z "$HIDAN_SIZE" "$HIDAN_SIZE" "$HIDAN_LOGO" --out "$HIDAN_ICONSET/icon_${HIDAN_SIZE}x${HIDAN_SIZE}.png" >/dev/null
  HIDAN_RETINA_SIZE=$((HIDAN_SIZE * 2))
  /usr/bin/sips -z "$HIDAN_RETINA_SIZE" "$HIDAN_RETINA_SIZE" "$HIDAN_LOGO" --out "$HIDAN_ICONSET/icon_${HIDAN_SIZE}x${HIDAN_SIZE}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$HIDAN_ICONSET" -o "$HIDAN_ICON_TMP/AppIcon.icns"
mv "$HIDAN_ICON_TMP/AppIcon.icns" "$HIDAN_ICON"
echo "Generated: $HIDAN_ICON"

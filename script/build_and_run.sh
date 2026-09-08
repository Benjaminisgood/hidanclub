#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_NAME="HidanClub"
BUNDLE_ID="club.hidan.mac"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
case "$MODE" in run|--build|--verify|--debug|--logs|--telemetry) ;; *) echo "usage: $0 [--build|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;; esac
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
BRAND_DIR="$ROOT_DIR/Sources/HidanClub/Resources/Brand"
if [ ! -f "$BRAND_DIR/AppIcon.icns" ] || [ "$BRAND_DIR/HidanLogo.png" -nt "$BRAND_DIR/AppIcon.icns" ]; then
  "$ROOT_DIR/script/generate_app_icon.sh"
fi
swift build
BIN_DIR="$(swift build --show-bin-path)"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$BRAND_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
if [ -d "$BIN_DIR/HidanClub_HidanClub.bundle" ]; then
  ditto "$BIN_DIR/HidanClub_HidanClub.bundle" "$APP_BUNDLE/Contents/Resources/HidanClub_HidanClub.bundle"
fi
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HidanClub</string>
<key>CFBundleIdentifier</key><string>club.hidan.mac</string>
<key>CFBundleName</key><string>Hidan Club</string>
<key>CFBundleDisplayName</key><string>Hidan Club</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP_BUNDLE"
case "$MODE" in
  --build) echo "Built: $APP_BUNDLE" ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 2; pgrep -x "$APP_NAME" >/dev/null; codesign --verify --deep --strict "$APP_BUNDLE"; echo "Launch and signature verified" ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "HidanClub"' ;;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "club.hidan.mac"' ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
esac

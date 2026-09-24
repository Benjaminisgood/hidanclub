#!/usr/bin/env bash
# Offscreen renders of the production「一起跳」page: lobby idle, hosting,
# join request, waiting, and the connected stage on both sides with a real
# loopback session carrying H.264 and joints. PNGs land in output/qa-party.
# No window is shown; no camera, microphone or Bonjour advertisement is used.
set -euo pipefail
HIDAN_UI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDAN_UI_QA="$(mktemp -d "${TMPDIR:-/tmp}/hidan-party-ui.XXXXXX")"
trap 'rm -rf "$HIDAN_UI_QA"' EXIT
HIDAN_UI_PNG="$HIDAN_UI_ROOT/output/qa-party"
cd "$HIDAN_UI_ROOT"
if [[ "$(uname -s)" != "Darwin" ]]; then echo "This UI probe requires macOS 14+." >&2; exit 1; fi
HIDAN_UI_ARCH="$(uname -m)"
case "$HIDAN_UI_ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $HIDAN_UI_ARCH" >&2; exit 1 ;; esac
HIDAN_UI_TARGET="$HIDAN_UI_ARCH-apple-macosx14.0"
# SwiftUI's @State/@Binding macros need Xcode's host plugin directory.
HIDAN_UI_PLUGINS="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
HIDAN_UI_MACRO_FLAGS=()
if [[ -f "$HIDAN_UI_PLUGINS/libSwiftUIMacros.dylib" ]]; then HIDAN_UI_MACRO_FLAGS+=(-plugin-path "$HIDAN_UI_PLUGINS"); fi
swiftc -swift-version 5 -target "$HIDAN_UI_TARGET" -emit-library -emit-module \
  -module-name HidanCore -emit-module-path "$HIDAN_UI_QA/HidanCore.swiftmodule" \
  Sources/HidanCore/*.swift -o "$HIDAN_UI_QA/libHidanCore.dylib"
swiftc -swift-version 5 -target "$HIDAN_UI_TARGET" \
  ${HIDAN_UI_MACRO_FLAGS[@]+"${HIDAN_UI_MACRO_FLAGS[@]}"} \
  -I "$HIDAN_UI_QA" -L "$HIDAN_UI_QA" -lHidanCore \
  -Xlinker -rpath -Xlinker "$HIDAN_UI_QA" \
  Sources/HidanClub/Services/LivePoseFrameTap.swift \
  Sources/HidanClub/Services/LivePoseCamera.swift \
  Sources/HidanClub/Services/CameraMovieRecorder.swift \
  Sources/HidanClub/Services/MusicService.swift \
  Sources/HidanClub/Services/PartyVideoCodec.swift \
  Sources/HidanClub/Services/PartyService.swift \
  Sources/HidanClub/Services/PartyMusicBridge.swift \
  Sources/HidanClub/Support/PlaybackControls.swift \
  Sources/HidanClub/Support/Theme.swift \
  Sources/HidanClub/Views/LivePoseCameraView.swift \
  Sources/HidanClub/Views/PartyView.swift \
  script/qa_party_ui_probe.swift -o "$HIDAN_UI_QA/PartyUIProbe"
mkdir -p "$HIDAN_UI_PNG"
"$HIDAN_UI_QA/PartyUIProbe" "$HIDAN_UI_PNG"

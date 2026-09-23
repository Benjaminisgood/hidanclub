#!/usr/bin/env bash
# Real macOS media checks with generated test files. Audio output is muted.
set -euo pipefail
HIDAN_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HIDAN_PROJECT_ROOT"
HIDAN_MEDIA_QA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hidan-media.XXXXXX")"
trap 'rm -rf "$HIDAN_MEDIA_QA_DIR"' EXIT
swiftc -swift-version 5 Sources/HidanClub/Services/VideoService.swift script/qa_video_probe.swift -o "$HIDAN_MEDIA_QA_DIR/video-probe"
"$HIDAN_MEDIA_QA_DIR/video-probe"
HIDAN_MEDIA_ARCH="$(uname -m)"
HIDAN_MEDIA_TARGET="$HIDAN_MEDIA_ARCH-apple-macosx14.0"
swiftc -swift-version 5 -target "$HIDAN_MEDIA_TARGET" -emit-library -emit-module \
  -module-name HidanCore -emit-module-path "$HIDAN_MEDIA_QA_DIR/HidanCore.swiftmodule" \
  Sources/HidanCore/*.swift -o "$HIDAN_MEDIA_QA_DIR/libHidanCore.dylib"
cat Sources/HidanClub/Services/MusicService.swift script/qa_music_probe.swift > "$HIDAN_MEDIA_QA_DIR/MusicProbe.swift"
swiftc -parse-as-library -swift-version 5 -target "$HIDAN_MEDIA_TARGET" \
  -I "$HIDAN_MEDIA_QA_DIR" -L "$HIDAN_MEDIA_QA_DIR" -lHidanCore \
  -Xlinker -rpath -Xlinker "$HIDAN_MEDIA_QA_DIR" \
  "$HIDAN_MEDIA_QA_DIR/MusicProbe.swift" -o "$HIDAN_MEDIA_QA_DIR/music-probe"
"$HIDAN_MEDIA_QA_DIR/music-probe"

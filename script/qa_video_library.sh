#!/usr/bin/env bash
# Isolated original-file persistence, full-frame analysis and selection-race checks.
set -euo pipefail
HIDAN_VIDEO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDAN_VIDEO_QA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hidan-video-library-tests.XXXXXX")"
trap 'rm -rf "$HIDAN_VIDEO_QA_DIR"' EXIT
cd "$HIDAN_VIDEO_ROOT"
HIDAN_VIDEO_ARCH="$(uname -m)"
swiftc -swift-version 5 -target "$HIDAN_VIDEO_ARCH-apple-macosx14.0" \
  Sources/HidanClub/Services/PoseAnalyzer.swift \
  Sources/HidanClub/Models/CapturedMotion.swift \
  Sources/HidanClub/Models/PoseArrangementPlanner.swift \
  Sources/HidanClub/Stores/CapturedMotionPlayback.swift \
  Sources/HidanClub/Stores/CapturedMotionStore.swift \
  Sources/HidanClub/Models/LibraryVideo.swift \
  Sources/HidanClub/Stores/VideoLibraryStore.swift \
  script/qa_video_library_probe.swift -o "$HIDAN_VIDEO_QA_DIR/VideoLibraryProbe"
"$HIDAN_VIDEO_QA_DIR/VideoLibraryProbe" "$HIDAN_VIDEO_QA_DIR"

#!/usr/bin/env bash
set -euo pipefail
HIDAN_LIBRARY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDAN_LIBRARY_QA="$(mktemp -d "${TMPDIR:-/tmp}/hidan-library-qa.XXXXXX")"
trap 'rm -rf "$HIDAN_LIBRARY_QA"' EXIT
cd "$HIDAN_LIBRARY_ROOT"
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  Sources/HidanClub/Services/PoseAnalyzer.swift \
  Sources/HidanClub/Models/CapturedMotion.swift \
  Sources/HidanClub/Models/PoseArrangementPlanner.swift \
  Sources/HidanClub/Stores/CapturedMotionPlayback.swift \
  Sources/HidanClub/Stores/CapturedMotionStore.swift \
  Sources/HidanClub/Stores/CapturedLibraryStore.swift \
  script/qa_video_motion_library_probe.swift -o "$HIDAN_LIBRARY_QA/LibraryProbe"
"$HIDAN_LIBRARY_QA/LibraryProbe" "$HIDAN_LIBRARY_QA/library"

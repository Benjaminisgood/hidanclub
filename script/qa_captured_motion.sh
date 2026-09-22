#!/usr/bin/env bash
# Production capture/model/playback contract tests. Uses a generated blank clip
# plus explicitly synthetic joint fixtures; it does not score pose accuracy.
set -euo pipefail
HIDAN_CAPTURE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDAN_CAPTURE_QA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hidan-capture-tests.XXXXXX")"
trap 'rm -rf "$HIDAN_CAPTURE_QA_DIR"' EXIT
cd "$HIDAN_CAPTURE_ROOT"
HIDAN_CAPTURE_ARCH="$(uname -m)"
case "$HIDAN_CAPTURE_ARCH" in
  arm64|x86_64) ;;
  *) echo "Capture QA requires a macOS developer environment." >&2; exit 1 ;;
esac
swiftc -swift-version 5 -target "$HIDAN_CAPTURE_ARCH-apple-macosx14.0" \
  Sources/HidanClub/Services/PoseAnalyzer.swift \
  Sources/HidanClub/Models/CapturedMotion.swift \
  Sources/HidanClub/Models/PoseArrangementPlanner.swift \
  Sources/HidanClub/Stores/CapturedMotionPlayback.swift \
  Sources/HidanClub/Stores/CapturedMotionStore.swift \
  script/qa_captured_motion_probe.swift -o "$HIDAN_CAPTURE_QA_DIR/CaptureProbe"
HIDAN_CAPTURE_DIR="$HIDAN_CAPTURE_QA_DIR/models" \
  "$HIDAN_CAPTURE_QA_DIR/CaptureProbe" "$HIDAN_CAPTURE_QA_DIR"

#!/usr/bin/env bash
# Permission-free lifecycle regression: injected outputs and temporary files.
set -euo pipefail
HIDAN_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDAN_RECORDING_QA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hidan-recording.XXXXXX")"
trap 'rm -rf "$HIDAN_RECORDING_QA_DIR"' EXIT
cd "$HIDAN_PROJECT_ROOT"
HIDAN_MAC_ARCH="$(uname -m)"
swiftc -parse-as-library -swift-version 5 -target "$HIDAN_MAC_ARCH-apple-macosx14.0" \
  Sources/HidanClub/Services/CameraMovieRecorder.swift script/qa_camera_recording_probe.swift \
  -o "$HIDAN_RECORDING_QA_DIR/camera-recording-probe"
HIDAN_RECORDING_DIR="$HIDAN_RECORDING_QA_DIR/PendingRecordings" "$HIDAN_RECORDING_QA_DIR/camera-recording-probe"

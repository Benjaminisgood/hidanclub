#!/usr/bin/env bash
# Permission-free tests: synthetic buffers only, never starts a capture session.
set -euo pipefail
HIDAN_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDAN_CAMERA_QA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hidan-live-pose.XXXXXX")"
trap 'rm -rf "$HIDAN_CAMERA_QA_DIR"' EXIT
cd "$HIDAN_PROJECT_ROOT"
HIDAN_MAC_ARCH="$(uname -m)"
swiftc -swift-version 5 -target "$HIDAN_MAC_ARCH-apple-macosx14.0" \
  -emit-library -emit-module -module-name HidanCore Sources/HidanCore/LivePoseFeedback.swift \
  -emit-module-path "$HIDAN_CAMERA_QA_DIR/HidanCore.swiftmodule" -o "$HIDAN_CAMERA_QA_DIR/libHidanCore.dylib"
# The probe shares this temporary source file to exercise the private production
# frame pipeline directly. No test-only camera entry point ships in the app.
cat Sources/HidanClub/Services/LivePoseCamera.swift script/qa_live_pose_probe.swift > "$HIDAN_CAMERA_QA_DIR/CameraProbe.swift"
swiftc -parse-as-library -swift-version 5 -target "$HIDAN_MAC_ARCH-apple-macosx14.0" \
  -I "$HIDAN_CAMERA_QA_DIR" -L "$HIDAN_CAMERA_QA_DIR" -lHidanCore \
  "$HIDAN_CAMERA_QA_DIR/CameraProbe.swift" Sources/HidanClub/Services/CameraMovieRecorder.swift Sources/HidanClub/Views/LivePoseCameraView.swift \
  -o "$HIDAN_CAMERA_QA_DIR/live-pose-probe"
DYLD_LIBRARY_PATH="$HIDAN_CAMERA_QA_DIR" "$HIDAN_CAMERA_QA_DIR/live-pose-probe"

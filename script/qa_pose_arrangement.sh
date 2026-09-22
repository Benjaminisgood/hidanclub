#!/usr/bin/env bash
# Synthetic pose fixtures test the editing contract, not human dance accuracy.
set -euo pipefail
HIDAN_ARRANGEMENT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDAN_ARRANGEMENT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hidan-arrangement-qa.XXXXXX")"
trap 'rm -rf "$HIDAN_ARRANGEMENT_TMP"' EXIT
cd "$HIDAN_ARRANGEMENT_ROOT"
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  Sources/HidanClub/Services/PoseAnalyzer.swift \
  Sources/HidanClub/Models/CapturedMotion.swift \
  Sources/HidanClub/Models/PoseArrangementPlanner.swift \
  Sources/HidanClub/Stores/CapturedMotionPlayback.swift \
  Sources/HidanClub/Stores/CapturedMotionStore.swift \
  script/qa_pose_arrangement_probe.swift -o "$HIDAN_ARRANGEMENT_TMP/ArrangementProbe"
"$HIDAN_ARRANGEMENT_TMP/ArrangementProbe" "$HIDAN_ARRANGEMENT_TMP"

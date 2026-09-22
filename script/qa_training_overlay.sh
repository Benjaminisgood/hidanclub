#!/usr/bin/env bash
# Render production AIST SceneKit overlays without building or launching the app.
# Source data is read-only. PNGs are written to the ignored output/ directory.
set -euo pipefail
HIDAN_OVERLAY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDAN_OVERLAY_DATA="${1:-${HIDAN_AIST_DIR:-$HOME/Library/Application Support/HidanClub/Datasets/AISTPlusPlus}}"
HIDAN_OVERLAY_OUTPUT="${2:-$HIDAN_OVERLAY_ROOT/output/qa-training-overlay}"
HIDAN_OVERLAY_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/hidan-overlay-tests.XXXXXX")"
trap 'rm -rf "$HIDAN_OVERLAY_TEMP"' EXIT
cd "$HIDAN_OVERLAY_ROOT"
if [[ "$(uname -s)" != "Darwin" || ! -f "$HIDAN_OVERLAY_DATA/manifest.json" ]]; then
  echo "Requires macOS and an installed AIST++ manifest; pass the dataset directory." >&2
  exit 1
fi
HIDAN_OVERLAY_ARCH="$(uname -m)"
swiftc -O -swift-version 5 -target "$HIDAN_OVERLAY_ARCH-apple-macosx14.0" \
  Sources/HidanCore/AISTModels.swift \
  Sources/HidanClub/Support/AISTVisualStyle.swift \
  Sources/HidanClub/Views/AISTStageRenderer.swift \
  Sources/HidanClub/Views/AISTAvatarRenderer.swift \
  Sources/HidanClub/Views/AISTSkeletonView.swift \
  script/qa_training_overlay_probe.swift \
  -o "$HIDAN_OVERLAY_TEMP/overlay-probe"
"$HIDAN_OVERLAY_TEMP/overlay-probe" "$HIDAN_OVERLAY_DATA" "$HIDAN_OVERLAY_OUTPUT"

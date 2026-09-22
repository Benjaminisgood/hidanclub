#!/usr/bin/env bash
# Directly exercises production SceneKit coordinators, without building or
# launching the main app. Dataset files are read-only; no frame reduction.
set -euo pipefail
HIDAN_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDAN_AIST_TEST_DATA="${1:-${HIDAN_AIST_DIR:-$HOME/Library/Application Support/HidanClub/Datasets/AISTPlusPlus}}"
HIDAN_APPEARANCE_QA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hidan-appearance-tests.XXXXXX")"
trap 'rm -rf "$HIDAN_APPEARANCE_QA_DIR"' EXIT
cd "$HIDAN_PROJECT_ROOT"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SceneKit appearance QA requires macOS 14+." >&2
  exit 1
fi
if [[ ! -f "$HIDAN_AIST_TEST_DATA/manifest.json" ]]; then
  echo "Install AIST++ with script/aist_dataset.py, or pass its directory." >&2
  exit 1
fi
HIDAN_APPEARANCE_ARCH="$(uname -m)"
case "$HIDAN_APPEARANCE_ARCH" in
  arm64|x86_64) ;;
  *) echo "Unsupported architecture: $HIDAN_APPEARANCE_ARCH" >&2; exit 1 ;;
esac
swiftc -O -swift-version 5 -target "$HIDAN_APPEARANCE_ARCH-apple-macosx14.0" \
  Sources/HidanCore/AISTModels.swift \
  Sources/HidanClub/Support/AISTVisualStyle.swift \
  Sources/HidanClub/Views/AISTStageRenderer.swift \
  Sources/HidanClub/Views/AISTAvatarRenderer.swift \
  Sources/HidanClub/Views/AISTSkeletonView.swift \
  script/qa_aist_appearance_probe.swift \
  -o "$HIDAN_APPEARANCE_QA_DIR/appearance-probe"
"$HIDAN_APPEARANCE_QA_DIR/appearance-probe" "$HIDAN_AIST_TEST_DATA"

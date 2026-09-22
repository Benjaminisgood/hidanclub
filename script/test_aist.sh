#!/usr/bin/env bash
# Validate the installed complete AIST++ v1.0 library with the production Swift
# loader. Reads every frame of both variants; no download or dataset mutation.
set -euo pipefail
HIDAN_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDAN_AIST_TEST_DATA="${1:-${HIDAN_AIST_DIR:-$HOME/Library/Application Support/HidanClub/Datasets/AISTPlusPlus}}"
HIDAN_AIST_QA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hidan-aist-tests.XXXXXX")"
trap 'rm -rf "$HIDAN_AIST_QA_DIR"' EXIT
cd "$HIDAN_PROJECT_ROOT"
swiftc -O -swift-version 5 Sources/HidanCore/AISTModels.swift script/qa_aist_probe.swift \
  -o "$HIDAN_AIST_QA_DIR/aist-probe"
"$HIDAN_AIST_QA_DIR/aist-probe" "$HIDAN_AIST_TEST_DATA" "$HIDAN_AIST_QA_DIR"

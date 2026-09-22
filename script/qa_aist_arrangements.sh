#!/usr/bin/env bash
# Compile only the core and arrangement store into a disposable QA executable.
# The application is neither built nor launched; dataset files stay read-only.
set -euo pipefail
HIDAN_ARR_QA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDAN_ARR_QA_DATA="${1:-${HIDAN_AIST_DIR:-$HOME/Library/Application Support/HidanClub/Datasets/AISTPlusPlus}}"
HIDAN_ARR_QA_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/hidan-arrangement-tests.XXXXXX")"
trap 'rm -rf "$HIDAN_ARR_QA_TEMP"' EXIT
cd "$HIDAN_ARR_QA_ROOT"
HIDAN_ARR_QA_TARGET="$(uname -m)-apple-macosx14.0"
swiftc -swift-version 5 -target "$HIDAN_ARR_QA_TARGET" -emit-library -emit-module \
  -module-name HidanCore -emit-module-path "$HIDAN_ARR_QA_TEMP/HidanCore.swiftmodule" \
  Sources/HidanCore/*.swift -o "$HIDAN_ARR_QA_TEMP/libHidanCore.dylib"
swiftc -swift-version 5 -target "$HIDAN_ARR_QA_TARGET" \
  -I "$HIDAN_ARR_QA_TEMP" -L "$HIDAN_ARR_QA_TEMP" -lHidanCore \
  -Xlinker -rpath -Xlinker "$HIDAN_ARR_QA_TEMP" \
  Sources/HidanClub/Stores/AISTArrangementStore.swift script/qa_aist_arrangements_probe.swift \
  -o "$HIDAN_ARR_QA_TEMP/arrangement-probe"
HIDAN_ARRANGEMENT_DIR="$HIDAN_ARR_QA_TEMP/state" \
  "$HIDAN_ARR_QA_TEMP/arrangement-probe" "$HIDAN_ARR_QA_DATA" "$HIDAN_ARR_QA_TEMP"

#!/usr/bin/env bash
# All persistent writes are confined to a disposable fixture directory.
set -euo pipefail
HIDAN_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HIDAN_PROJECT_ROOT"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "TrainingStore uses AppKit/SwiftUI; this probe requires macOS 14+." >&2
  exit 1
fi
HIDAN_STORE_QA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hidan-store-tests.XXXXXX")"
trap 'rm -rf "$HIDAN_STORE_QA_DIR"' EXIT
HIDAN_STORE_ARCH="$(uname -m)"
case "$HIDAN_STORE_ARCH" in
  arm64|x86_64) ;;
  *) echo "Unsupported macOS architecture: $HIDAN_STORE_ARCH" >&2; exit 1 ;;
esac
HIDAN_STORE_TARGET="$HIDAN_STORE_ARCH-apple-macosx14.0"

swiftc -swift-version 5 -target "$HIDAN_STORE_TARGET" -emit-library -emit-module \
  -module-name HidanCore -emit-module-path "$HIDAN_STORE_QA_DIR/HidanCore.swiftmodule" \
  Sources/HidanCore/*.swift -o "$HIDAN_STORE_QA_DIR/libHidanCore.dylib"
swiftc -swift-version 5 -target "$HIDAN_STORE_TARGET" \
  -I "$HIDAN_STORE_QA_DIR" -L "$HIDAN_STORE_QA_DIR" -lHidanCore \
  -Xlinker -rpath -Xlinker "$HIDAN_STORE_QA_DIR" \
  Sources/HidanClub/Stores/TrainingStore.swift script/qa_store_probe.swift \
  -o "$HIDAN_STORE_QA_DIR/store-probe"

for HIDAN_STORE_SCENARIO in normal corrupt write-failure; do
  HIDAN_STORE_PROBE=1 HIDAN_DATA_DIR="$HIDAN_STORE_QA_DIR/$HIDAN_STORE_SCENARIO" \
    "$HIDAN_STORE_QA_DIR/store-probe" "$HIDAN_STORE_SCENARIO"
done
echo "STORE PROBE PASSED: actual session persistence, deduplication, corruption preservation, and explicit write-error recovery. User history was not accessed."

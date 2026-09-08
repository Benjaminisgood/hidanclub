#!/usr/bin/env bash
# Run meaningful regression probes even when Apple's Command Line Tools omit
# XCTest. If XCTest is available, also run the original package test suite.
set -euo pipefail

HIDAN_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HIDAN_PROJECT_ROOT"
HIDAN_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hidan-tests.XXXXXX")"
trap 'rm -rf "$HIDAN_TEST_DIR"' EXIT

echo "Running Foundation-only HidanCore regression harness…"
swiftc -swift-version 5 Sources/HidanCore/*.swift script/qa_core_probe.swift -o "$HIDAN_TEST_DIR/core-probe"
"$HIDAN_TEST_DIR/core-probe"

if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "Running full-frame pose decoder regression harness…"
  HIDAN_MAC_ARCH="$(uname -m)"
  case "$HIDAN_MAC_ARCH" in
    arm64|x86_64) ;;
    *) echo "Unsupported macOS architecture: $HIDAN_MAC_ARCH" >&2; exit 1 ;;
  esac
  swiftc -swift-version 5 -target "$HIDAN_MAC_ARCH-apple-macosx14.0" \
    Sources/HidanClub/Services/PoseAnalyzer.swift script/qa_pose_probe.swift \
    -o "$HIDAN_TEST_DIR/pose-probe"
  "$HIDAN_TEST_DIR/pose-probe"
else
  echo "Pose probe requires macOS 14+ and Apple Vision/AVFoundation; skipping on $(uname -s)."
fi

printf '%s\n' 'import XCTest' > "$HIDAN_TEST_DIR/xctest-availability.swift"
if swiftc -typecheck "$HIDAN_TEST_DIR/xctest-availability.swift" 2> "$HIDAN_TEST_DIR/xctest-availability.log"; then
  echo "XCTest is available; running the original Swift package test suite…"
  swift test
elif /usr/bin/grep -Fq "error: no such module 'XCTest'" "$HIDAN_TEST_DIR/xctest-availability.log"; then
  echo "XCTest is unavailable in this developer-tool installation (no such module 'XCTest')."
  echo "Standalone regression probes passed. XCTest files are preserved; run this script with full Xcode selected to also execute swift test."
else
  echo "Unexpected failure checking XCTest availability; refusing to hide it behind the standalone fallback." >&2
  cat "$HIDAN_TEST_DIR/xctest-availability.log" >&2
  exit 1
fi

#!/usr/bin/env bash
# Library import QA. Reads a real exported motion file (read-only, hashed before
# and after) and verifies publication into 动作库/编排库, lenient packaging and
# named refusals. usage: script/qa_library_import.sh [motion.json]
set -euo pipefail
HIDAN_IMPORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDAN_IMPORT_QA="$(mktemp -d "${TMPDIR:-/tmp}/hidan-import-qa.XXXXXX")"
trap 'rm -rf "$HIDAN_IMPORT_QA"' EXIT
cd "$HIDAN_IMPORT_ROOT"
MOTION_FILE="${1:-$HOME/Desktop/center-dancer.hidanclub.json}"
if [ ! -f "$MOTION_FILE" ]; then
  echo "需要一份真实的动作模型 JSON 作为输入：$MOTION_FILE 不存在。" >&2
  echo "usage: $0 [motion.json]" >&2
  exit 2
fi
echo "Import QA input: $MOTION_FILE"
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  Sources/HidanClub/Services/PoseAnalyzer.swift \
  Sources/HidanClub/Models/CapturedMotion.swift \
  Sources/HidanClub/Models/CapturedMotionImport.swift \
  Sources/HidanClub/Models/PoseArrangementPlanner.swift \
  Sources/HidanClub/Stores/CapturedMotionPlayback.swift \
  Sources/HidanClub/Stores/CapturedMotionStore.swift \
  Sources/HidanClub/Stores/CapturedLibraryStore.swift \
  script/qa_library_import_probe.swift -o "$HIDAN_IMPORT_QA/ImportProbe"
"$HIDAN_IMPORT_QA/ImportProbe" "$HIDAN_IMPORT_QA/library" "$MOTION_FILE" "$HIDAN_IMPORT_QA/variants"

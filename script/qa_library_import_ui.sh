#!/usr/bin/env bash
# Offscreen render of the production import UI. An isolated library is filled
# through the production import path with a real exported motion file, then the
# real 编排库 page, 动作库 detail, import control and clip card are rendered to
# PNG. The user's real library is never touched.
# usage: script/qa_library_import_ui.sh [motion.json]
set -euo pipefail
HIDAN_UI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDAN_UI_QA="$(mktemp -d "${TMPDIR:-/tmp}/hidan-import-ui.XXXXXX")"
trap 'rm -rf "$HIDAN_UI_QA"' EXIT
HIDAN_UI_PNG="$HIDAN_UI_ROOT/output/qa-library-import"
cd "$HIDAN_UI_ROOT"
MOTION_FILE="${1:-$HOME/Desktop/center-dancer.hidanclub.json}"
if [[ "$(uname -s)" != "Darwin" ]]; then echo "This UI probe requires macOS 14+." >&2; exit 1; fi
if [ ! -f "$MOTION_FILE" ]; then
  echo "需要一份真实的动作模型 JSON 作为输入：$MOTION_FILE 不存在。" >&2
  echo "usage: $0 [motion.json]" >&2
  exit 2
fi
HIDAN_UI_ARCH="$(uname -m)"
case "$HIDAN_UI_ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $HIDAN_UI_ARCH" >&2; exit 1 ;; esac
HIDAN_UI_TARGET="$HIDAN_UI_ARCH-apple-macosx14.0"
# SwiftUI's @State/@Binding macros need Xcode's host plugin directory.
HIDAN_UI_PLUGINS="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
HIDAN_UI_MACRO_FLAGS=()
if [[ -f "$HIDAN_UI_PLUGINS/libSwiftUIMacros.dylib" ]]; then HIDAN_UI_MACRO_FLAGS+=(-plugin-path "$HIDAN_UI_PLUGINS"); fi
echo "Import UI probe input: $MOTION_FILE"
swiftc -swift-version 5 -target "$HIDAN_UI_TARGET" -emit-library -emit-module \
  -module-name HidanCore -emit-module-path "$HIDAN_UI_QA/HidanCore.swiftmodule" \
  Sources/HidanCore/*.swift -o "$HIDAN_UI_QA/libHidanCore.dylib"
swiftc -swift-version 5 -target "$HIDAN_UI_TARGET" \
  ${HIDAN_UI_MACRO_FLAGS[@]+"${HIDAN_UI_MACRO_FLAGS[@]}"} \
  -I "$HIDAN_UI_QA" -L "$HIDAN_UI_QA" -lHidanCore \
  -Xlinker -rpath -Xlinker "$HIDAN_UI_QA" \
  Sources/HidanClub/Services/PoseAnalyzer.swift \
  Sources/HidanClub/Models/CapturedMotion.swift \
  Sources/HidanClub/Models/CapturedMotionImport.swift \
  Sources/HidanClub/Models/PoseArrangementPlanner.swift \
  Sources/HidanClub/Stores/CapturedMotionPlayback.swift \
  Sources/HidanClub/Stores/CapturedMotionStore.swift \
  Sources/HidanClub/Stores/CapturedLibraryStore.swift \
  Sources/HidanClub/Stores/AISTArrangementStore.swift \
  Sources/HidanClub/Support/Theme.swift \
  Sources/HidanClub/Views/ImportedMotionLibraryView.swift \
  Sources/HidanClub/Views/LibraryImportView.swift \
  Sources/HidanClub/Views/CapturedMotionView.swift \
  Sources/HidanClub/Views/SequenceView.swift \
  script/qa_library_import_ui_probe.swift -o "$HIDAN_UI_QA/LibraryImportUIProbe"
mkdir -p "$HIDAN_UI_PNG"
"$HIDAN_UI_QA/LibraryImportUIProbe" "$HIDAN_UI_QA/library" "$HIDAN_UI_QA/arrangements" "$MOTION_FILE" "$HIDAN_UI_PNG"

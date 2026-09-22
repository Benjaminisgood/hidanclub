#!/usr/bin/env bash
# Production stores, real dataset read-only, disposable history and unique app
# preference domain. No main application build, video downloads or media playback.
set -euo pipefail
HIDAN_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDAN_AIST_TEST_DATA="${1:-${HIDAN_AIST_DIR:-$HOME/Library/Application Support/HidanClub/Datasets/AISTPlusPlus}}"
HIDAN_AIST_STORE_QA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hidan-aist-store-tests.XXXXXX")"
trap 'rm -rf "$HIDAN_AIST_STORE_QA_DIR"' EXIT
cd "$HIDAN_PROJECT_ROOT"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "AIST/Training stores require macOS 14+." >&2
  exit 1
fi
if [[ ! -f "$HIDAN_AIST_TEST_DATA/manifest.json" ]]; then
  echo "Install the complete dataset with script/aist_dataset.py first, or pass its directory." >&2
  exit 1
fi
HIDAN_AIST_STORE_ARCH="$(uname -m)"
case "$HIDAN_AIST_STORE_ARCH" in
  arm64|x86_64) ;;
  *) echo "Unsupported architecture: $HIDAN_AIST_STORE_ARCH" >&2; exit 1 ;;
esac
HIDAN_AIST_STORE_TARGET="$HIDAN_AIST_STORE_ARCH-apple-macosx14.0"
HIDAN_AIST_QA_APP="$HIDAN_AIST_STORE_QA_DIR/AISTStoreQA.app"
HIDAN_AIST_QA_BUNDLE="$HIDAN_AIST_STORE_QA_DIR/QAResources.bundle"
HIDAN_AIST_QA_IDENTIFIER="org.hidanclub.qa.$(uuidgen | tr '[:upper:]' '[:lower:]')"
mkdir -p "$HIDAN_AIST_QA_APP/Contents/MacOS" "$HIDAN_AIST_QA_BUNDLE/Contents/Resources/Resources/AIST"
/usr/bin/plutil -create xml1 "$HIDAN_AIST_QA_APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string "$HIDAN_AIST_QA_IDENTIFIER" "$HIDAN_AIST_QA_APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string AISTStoreProbe "$HIDAN_AIST_QA_APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$HIDAN_AIST_QA_APP/Contents/Info.plist"
/usr/bin/plutil -create xml1 "$HIDAN_AIST_QA_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string "$HIDAN_AIST_QA_IDENTIFIER.resources" "$HIDAN_AIST_QA_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string BNDL "$HIDAN_AIST_QA_BUNDLE/Contents/Info.plist"
cp Sources/HidanClub/Resources/AIST/choreography-names.json "$HIDAN_AIST_QA_BUNDLE/Contents/Resources/Resources/AIST/"
cp Sources/HidanClub/Resources/AIST/training-moves.json "$HIDAN_AIST_QA_BUNDLE/Contents/Resources/Resources/AIST/"

cat > "$HIDAN_AIST_STORE_QA_DIR/BundleModule.swift" <<'SWIFT'
import Foundation
// This accessor replaces SwiftPM's generated accessor only in this QA executable.
extension Bundle {
    static let module: Bundle = {
        guard let path = ProcessInfo.processInfo.environment["HIDAN_QA_RESOURCE_BUNDLE"],
              let bundle = Bundle(path: path) else { fatalError("Missing isolated QA resource bundle") }
        return bundle
    }()
}
SWIFT

swiftc -swift-version 5 -target "$HIDAN_AIST_STORE_TARGET" -emit-library -emit-module \
  -module-name HidanCore -emit-module-path "$HIDAN_AIST_STORE_QA_DIR/HidanCore.swiftmodule" \
  Sources/HidanCore/*.swift -o "$HIDAN_AIST_STORE_QA_DIR/libHidanCore.dylib"
swiftc -swift-version 5 -target "$HIDAN_AIST_STORE_TARGET" \
  -I "$HIDAN_AIST_STORE_QA_DIR" -L "$HIDAN_AIST_STORE_QA_DIR" -lHidanCore \
  -Xlinker -rpath -Xlinker "$HIDAN_AIST_STORE_QA_DIR" \
  Sources/HidanClub/Stores/TrainingStore.swift script/qa_aist_practice_probe.swift \
  -o "$HIDAN_AIST_STORE_QA_DIR/practice-probe"
HIDAN_AIST_STORE_QA=1 HIDAN_AIST_DIR="$HIDAN_AIST_TEST_DATA" \
  HIDAN_DATA_DIR="$HIDAN_AIST_STORE_QA_DIR/history-fixture" \
  "$HIDAN_AIST_STORE_QA_DIR/practice-probe"

swiftc -swift-version 5 -target "$HIDAN_AIST_STORE_TARGET" \
  -I "$HIDAN_AIST_STORE_QA_DIR" -L "$HIDAN_AIST_STORE_QA_DIR" -lHidanCore \
  -Xlinker -rpath -Xlinker "$HIDAN_AIST_STORE_QA_DIR" \
  Sources/HidanClub/Stores/TrainingStore.swift script/qa_aist_training_plan_probe.swift \
  -o "$HIDAN_AIST_STORE_QA_DIR/training-plan-probe"
HIDAN_AIST_STORE_QA=1 HIDAN_AIST_DIR="$HIDAN_AIST_TEST_DATA" \
  HIDAN_TRAINING_MOVES_FILE="$HIDAN_PROJECT_ROOT/Sources/HidanClub/Resources/AIST/training-moves.json" \
  HIDAN_DATA_DIR="$HIDAN_AIST_STORE_QA_DIR/demonstration-history-fixture" \
  "$HIDAN_AIST_STORE_QA_DIR/training-plan-probe"

swiftc -swift-version 5 -target "$HIDAN_AIST_STORE_TARGET" \
  -I "$HIDAN_AIST_STORE_QA_DIR" -L "$HIDAN_AIST_STORE_QA_DIR" -lHidanCore \
  -Xlinker -rpath -Xlinker "$HIDAN_AIST_STORE_QA_DIR" \
  "$HIDAN_AIST_STORE_QA_DIR/BundleModule.swift" \
  Sources/HidanClub/Stores/AISTLibraryStore.swift script/qa_aist_library_probe.swift \
  -o "$HIDAN_AIST_QA_APP/Contents/MacOS/AISTStoreProbe"
HIDAN_AIST_STORE_QA=1 HIDAN_AIST_DIR="$HIDAN_AIST_TEST_DATA" \
  HIDAN_QA_RESOURCE_BUNDLE="$HIDAN_AIST_QA_BUNDLE" HIDAN_QA_DEFAULTS_DOMAIN="$HIDAN_AIST_QA_IDENTIFIER" \
  "$HIDAN_AIST_QA_APP/Contents/MacOS/AISTStoreProbe"
echo "AIST STORE QA PASSED: training references and asynchronous library behavior. Dataset remained read-only; history and preference writes were isolated."

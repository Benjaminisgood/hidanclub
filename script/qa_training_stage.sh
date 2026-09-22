#!/usr/bin/env bash
# Exercise the production training demonstration coordinator without opening UI
# or playing audio. Real AIST data is read-only; history, preferences, fixtures,
# resources, and compiler products belong to a disposable QA application.
set -euo pipefail

HIDAN_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDAN_STAGE_DATA="${1:-${HIDAN_AIST_DIR:-$HOME/Library/Application Support/HidanClub/Datasets/AISTPlusPlus}}"
HIDAN_STAGE_QA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hidan-training-stage-tests.XXXXXX")"
HIDAN_STAGE_IDENTIFIER="org.hidanclub.qa.training-stage.$(uuidgen | tr '[:upper:]' '[:lower:]')"
cleanup() {
  /usr/bin/defaults delete "$HIDAN_STAGE_IDENTIFIER" >/dev/null 2>&1 || true
  rm -rf "$HIDAN_STAGE_QA_DIR"
}
trap cleanup EXIT
cd "$HIDAN_PROJECT_ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Training demonstration QA requires macOS 14+." >&2
  exit 1
fi
if [[ ! -f "$HIDAN_STAGE_DATA/manifest.json" ]]; then
  echo "Install AIST++ with script/aist_dataset.py, or pass the installed dataset directory." >&2
  exit 1
fi
HIDAN_STAGE_ARCH="$(uname -m)"
case "$HIDAN_STAGE_ARCH" in
  arm64|x86_64) ;;
  *) echo "Unsupported architecture: $HIDAN_STAGE_ARCH" >&2; exit 1 ;;
esac
HIDAN_STAGE_TARGET="$HIDAN_STAGE_ARCH-apple-macosx14.0"
HIDAN_STAGE_APP="$HIDAN_STAGE_QA_DIR/TrainingStageQA.app"
HIDAN_STAGE_BUNDLE="$HIDAN_STAGE_QA_DIR/QAResources.bundle"
mkdir -p "$HIDAN_STAGE_APP/Contents/MacOS" "$HIDAN_STAGE_BUNDLE/Contents/Resources/Resources/AIST" "$HIDAN_STAGE_QA_DIR/index-only"
/usr/bin/plutil -create xml1 "$HIDAN_STAGE_APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string "$HIDAN_STAGE_IDENTIFIER" "$HIDAN_STAGE_APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string TrainingStageProbe "$HIDAN_STAGE_APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$HIDAN_STAGE_APP/Contents/Info.plist"
/usr/bin/plutil -create xml1 "$HIDAN_STAGE_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string "$HIDAN_STAGE_IDENTIFIER.resources" "$HIDAN_STAGE_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string BNDL "$HIDAN_STAGE_BUNDLE/Contents/Info.plist"
cp Sources/HidanClub/Resources/AIST/choreography-names.json Sources/HidanClub/Resources/AIST/training-moves.json "$HIDAN_STAGE_BUNDLE/Contents/Resources/Resources/AIST/"
cp "$HIDAN_STAGE_DATA/manifest.json" "$HIDAN_STAGE_QA_DIR/index-only/manifest.json"

cat > "$HIDAN_STAGE_QA_DIR/BundleModule.swift" <<'SWIFT'
import Foundation
// Replace only SwiftPM's generated accessor for this isolated executable.
extension Bundle {
    static let module: Bundle = {
        guard let path = ProcessInfo.processInfo.environment["HIDAN_QA_RESOURCE_BUNDLE"],
              let bundle = Bundle(path: path) else { fatalError("Missing isolated QA resources") }
        return bundle
    }()
}
SWIFT

swiftc -swift-version 5 -target "$HIDAN_STAGE_TARGET" -emit-library -emit-module \
  -module-name HidanCore -emit-module-path "$HIDAN_STAGE_QA_DIR/HidanCore.swiftmodule" \
  Sources/HidanCore/*.swift -o "$HIDAN_STAGE_QA_DIR/libHidanCore.dylib"
swiftc -swift-version 5 -target "$HIDAN_STAGE_TARGET" \
  -I "$HIDAN_STAGE_QA_DIR" -L "$HIDAN_STAGE_QA_DIR" -lHidanCore \
  -Xlinker -rpath -Xlinker "$HIDAN_STAGE_QA_DIR" \
  "$HIDAN_STAGE_QA_DIR/BundleModule.swift" \
  Sources/HidanClub/Stores/TrainingStore.swift \
  Sources/HidanClub/Stores/AISTLibraryStore.swift \
  Sources/HidanClub/Stores/TrainingDemonstrationStore.swift \
  script/qa_training_stage_probe.swift \
  -o "$HIDAN_STAGE_APP/Contents/MacOS/TrainingStageProbe"

HIDAN_TRAINING_STAGE_QA=normal HIDAN_AIST_DIR="$HIDAN_STAGE_DATA" \
  HIDAN_DATA_DIR="$HIDAN_STAGE_QA_DIR/history-normal" \
  HIDAN_QA_RESOURCE_BUNDLE="$HIDAN_STAGE_BUNDLE" HIDAN_QA_DEFAULTS_DOMAIN="$HIDAN_STAGE_IDENTIFIER" \
  "$HIDAN_STAGE_APP/Contents/MacOS/TrainingStageProbe"
HIDAN_TRAINING_STAGE_QA=missing HIDAN_AIST_DIR="$HIDAN_STAGE_QA_DIR/missing-dataset" \
  HIDAN_DATA_DIR="$HIDAN_STAGE_QA_DIR/history-missing" \
  HIDAN_QA_RESOURCE_BUNDLE="$HIDAN_STAGE_BUNDLE" HIDAN_QA_DEFAULTS_DOMAIN="$HIDAN_STAGE_IDENTIFIER" \
  "$HIDAN_STAGE_APP/Contents/MacOS/TrainingStageProbe"
HIDAN_TRAINING_STAGE_QA=index-only HIDAN_AIST_DIR="$HIDAN_STAGE_QA_DIR/index-only" \
  HIDAN_DATA_DIR="$HIDAN_STAGE_QA_DIR/history-index-only" \
  HIDAN_QA_RESOURCE_BUNDLE="$HIDAN_STAGE_BUNDLE" HIDAN_QA_DEFAULTS_DOMAIN="$HIDAN_STAGE_IDENTIFIER" \
  "$HIDAN_STAGE_APP/Contents/MacOS/TrainingStageProbe"
echo "TRAINING STAGE QA PASSED: automatic references, playback state, cancellation, custom ranges, all styles, and missing-data blocking."

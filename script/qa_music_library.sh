#!/usr/bin/env bash
# Isolated music library: original bytes, local tempo estimate, manual BPM and selection.
set -euo pipefail
HIDAN_MUSIC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDAN_MUSIC_QA="$(mktemp -d "${TMPDIR:-/tmp}/hidan-music-library.XXXXXX")"
trap 'rm -rf "$HIDAN_MUSIC_QA"' EXIT
cd "$HIDAN_MUSIC_ROOT"
if [[ "$(uname -s)" != "Darwin" ]]; then echo "Music library QA requires macOS 14+." >&2; exit 1; fi
HIDAN_MUSIC_ARCH="$(uname -m)"
case "$HIDAN_MUSIC_ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $HIDAN_MUSIC_ARCH" >&2; exit 1 ;; esac
HIDAN_MUSIC_TARGET="$HIDAN_MUSIC_ARCH-apple-macosx14.0"
swiftc -swift-version 5 -target "$HIDAN_MUSIC_TARGET" -emit-library -emit-module \
  -module-name HidanCore -emit-module-path "$HIDAN_MUSIC_QA/HidanCore.swiftmodule" \
  Sources/HidanCore/*.swift -o "$HIDAN_MUSIC_QA/libHidanCore.dylib"
swiftc -swift-version 5 -target "$HIDAN_MUSIC_TARGET" \
  -I "$HIDAN_MUSIC_QA" -L "$HIDAN_MUSIC_QA" -lHidanCore \
  -Xlinker -rpath -Xlinker "$HIDAN_MUSIC_QA" \
  Sources/HidanClub/Services/MusicBeatAnalyzer.swift \
  Sources/HidanClub/Models/LibraryTrack.swift \
  Sources/HidanClub/Stores/MusicLibraryStore.swift \
  script/qa_music_library_probe.swift -o "$HIDAN_MUSIC_QA/MusicLibraryProbe"
"$HIDAN_MUSIC_QA/MusicLibraryProbe" "$HIDAN_MUSIC_QA"

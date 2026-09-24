#!/usr/bin/env bash
# Loopback regression for「一起跳」: two PartyService instances in one process
# over 127.0.0.1 with the production TLS-PSK parameters, plus an H.264
# encode/decode round trip on synthetic frames. No camera, Bonjour
# advertisement or local-network prompt is involved.
set -euo pipefail
HIDAN_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIDAN_PARTY_QA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hidan-party.XXXXXX")"
trap 'rm -rf "$HIDAN_PARTY_QA_DIR"' EXIT
cd "$HIDAN_PROJECT_ROOT"
HIDAN_MAC_ARCH="$(uname -m)"
swiftc -swift-version 5 -target "$HIDAN_MAC_ARCH-apple-macosx14.0" \
  -emit-library -emit-module -module-name HidanCore Sources/HidanCore/*.swift \
  -emit-module-path "$HIDAN_PARTY_QA_DIR/HidanCore.swiftmodule" -o "$HIDAN_PARTY_QA_DIR/libHidanCore.dylib"
swiftc -parse-as-library -swift-version 5 -target "$HIDAN_MAC_ARCH-apple-macosx14.0" \
  -I "$HIDAN_PARTY_QA_DIR" -L "$HIDAN_PARTY_QA_DIR" -lHidanCore \
  Sources/HidanClub/Services/LivePoseFrameTap.swift \
  Sources/HidanClub/Services/PartyVideoCodec.swift \
  Sources/HidanClub/Services/PartyService.swift \
  script/qa_party_probe.swift \
  -o "$HIDAN_PARTY_QA_DIR/party-probe"
DYLD_LIBRARY_PATH="$HIDAN_PARTY_QA_DIR" "$HIDAN_PARTY_QA_DIR/party-probe"

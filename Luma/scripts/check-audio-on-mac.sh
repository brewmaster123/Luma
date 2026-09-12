#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
LUMA_AUDIO_CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$LUMA_AUDIO_CHECK_DIR"' EXIT
xcrun swiftc -swift-version 5 Sources/LumaCore/*.swift Sources/Platform/AppError.swift \
  Sources/iPhone/CueAudioImporter.swift scripts/check-audio-on-mac.swift -o "$LUMA_AUDIO_CHECK_DIR/check-audio"
"$LUMA_AUDIO_CHECK_DIR/check-audio"

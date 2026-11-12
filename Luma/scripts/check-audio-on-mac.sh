#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/validation
LUMA_AUDIO_CHECK_DIR="$(mktemp -d .build/validation/audio.XXXXXX)"
trap 'rm -rf "$LUMA_AUDIO_CHECK_DIR"' EXIT
xcrun swiftc -swift-version 5 Sources/LumaCore/*.swift Sources/Platform/AppError.swift \
  Sources/iPhone/CueAudioImporter.swift Sources/iPhone/AlarmKitSoundBuilder.swift \
  scripts/check-audio-on-mac.swift -o "$LUMA_AUDIO_CHECK_DIR/check-audio"
"$LUMA_AUDIO_CHECK_DIR/check-audio"

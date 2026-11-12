#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
LUMA_QUEUE_CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$LUMA_QUEUE_CHECK_DIR"' EXIT
xcrun swiftc -swift-version 5 Sources/LumaCore/*.swift Sources/Platform/AppError.swift \
  Sources/Platform/AlarmScheduling.swift Sources/Platform/NotificationService.swift Sources/Platform/CueDiagnostics.swift \
  Sources/iPhone/CueAudioImporter.swift Sources/iPhone/AlarmKitSoundBuilder.swift \
  Sources/iPhone/AlarmKitScheduler.swift Sources/iPhone/LegacyAlarmCleanup.swift Sources/iPhone/SystemAlarmService.swift \
  scripts/check-finite-queue-on-mac.swift -o "$LUMA_QUEUE_CHECK_DIR/check-queue"
"$LUMA_QUEUE_CHECK_DIR/check-queue"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Install Xcode on a Mac, select it with xcode-select, then rerun this script."
  exit 1
fi
test "$(xcrun --sdk iphoneos --show-sdk-version | cut -d. -f1)" -ge 26
python3 scripts/check-static.py
swift test
bash scripts/check-audio-on-mac.sh
xcodebuild -project Luma.xcodeproj -scheme Luma -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/phone CODE_SIGNING_ALLOWED=NO build

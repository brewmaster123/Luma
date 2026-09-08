#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Install Xcode on a Mac, select it with xcode-select, then rerun this script."
  exit 1
fi
swift test
xcodebuild -project Luma.xcodeproj -scheme 'Luma Watch' -destination 'generic/platform=watchOS Simulator' -derivedDataPath .build/watch CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Luma.xcodeproj -scheme Luma -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/phone CODE_SIGNING_ALLOWED=NO build

#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
python3 scripts/prepare_app.py
xcodebuild -project .generated/RoamControl/RoamControl.xcodeproj -scheme RoamControl \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .generated/Simulator CODE_SIGNING_ALLOWED=NO build \
  > .generated/simulator-build.log 2>&1
DEVICE="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
items=json.load(sys.stdin)["devices"]
phones=[d["udid"] for runtime, devices in items.items() if "iOS-27" in runtime for d in devices if "iPhone" in d["name"]]
if not phones: raise SystemExit("No available iOS 27 iPhone simulator")
print(phones[0])')"
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
APP=".generated/Simulator/Build/Products/Debug-iphonesimulator/RoamControl.app"
xcrun simctl install "$DEVICE" "$APP"
mkdir -p .generated/ui-smoke
for PAGE in home bookmarks route-editor; do
  xcrun simctl terminate "$DEVICE" com.www10177.ifakegps.ios 2>/dev/null || true
  xcrun simctl launch "$DEVICE" com.www10177.ifakegps.ios \
    --skip-onboarding --ui-smoke "--show-$PAGE" -AppleLanguages '(zh-Hant)' -AppleLocale zh_TW
  sleep 3
  xcrun simctl io "$DEVICE" screenshot ".generated/ui-smoke/$PAGE.png"
done
xcrun simctl terminate "$DEVICE" com.www10177.ifakegps.ios

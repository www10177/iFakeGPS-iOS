#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
    echo "IPA builds need macOS + Xcode 27. Use Swift tests on Linux or the GitHub Actions build." >&2
    exit 1
fi
SDK="$(xcrun --sdk iphoneos --show-sdk-version)"
if [[ "${SDK%%.*}" -lt 27 ]]; then
    echo "An iOS 27 or newer SDK is required; selected SDK is $SDK." >&2
    exit 1
fi
python3 "$ROOT/scripts/prepare_app.py"
mkdir -p "$ROOT/dist"
xcodebuild -project "$ROOT/.generated/RoamControl/RoamControl.xcodeproj" \
    -scheme RoamControl -configuration Release -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -archivePath "$ROOT/.generated/iFakeGPS.xcarchive" \
    -derivedDataPath "$ROOT/.generated/DerivedData" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
    "ROAMCONTROL_BUILD_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    archive 2>&1 | tee "$ROOT/.generated/build.log"
APP="$ROOT/.generated/iFakeGPS.xcarchive/Products/Applications/RoamControl.app"
test -f "$APP/Info.plist"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/Payload"
ditto "$APP" "$TMP/Payload/iFakeGPS.app"
ditto -c -k --sequesterRsrc --keepParent "$TMP/Payload" "$ROOT/dist/iFakeGPS-iOS-unsigned.ipa"
echo "Created dist/iFakeGPS-iOS-unsigned.ipa. Sign during sideloading; this is not an unsigned-install bypass."

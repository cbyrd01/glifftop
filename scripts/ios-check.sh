#!/bin/sh
# GliffKit must compile for iOS: build it for the iOS Simulator SDK.
# Falls back to a plain SwiftPM cross-build if Xcode's iOS platform isn't installed.
set -eu
cd "$(dirname "$0")/../Packages/GliffKit"

# Xcode names the all-products scheme GliffKit-Package only once there are several products.
scheme=GliffKit
xcodebuild -list 2>/dev/null | grep -qx '[[:space:]]*GliffKit-Package' && scheme=GliffKit-Package

if xcodebuild -showdestinations -scheme "$scheme" 2>/dev/null | grep -q 'platform:iOS Simulator'; then
    exec xcodebuild -quiet -scheme "$scheme" -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath ../../.build/ios-check build
fi

echo "ios-check: iOS platform not installed; falling back to swift build for the simulator SDK." >&2
exec swift build --scratch-path ../../.build/ios-check-spm \
    --triple arm64-apple-ios27.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"

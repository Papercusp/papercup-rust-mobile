#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run the iOS XCTest unit suite. Builds the Papercup app target +
# the PapercupTests bundle individually (instead of via the scheme's
# build-for-testing action) because that avoids the Xcode 16.2
# destination-resolver race that the scheme path trips reliably
# after Sentry SwiftPM resolution slowed the package init.
#
# PAPERCUP_IOS_SIM_UDID overrides the sim picker; defaults to the
# first available iPhone 16.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/ios"

if [ -z "${PAPERCUP_IOS_SIM_UDID:-}" ]; then
    PAPERCUP_IOS_SIM_UDID=$(xcrun simctl list devices available \
        | awk -F '[()]' '/iPhone 16 \(/{print $2; exit}')
fi
if [ -z "$PAPERCUP_IOS_SIM_UDID" ]; then
    echo "ERROR: no iPhone 16 simulator found and PAPERCUP_IOS_SIM_UDID unset" >&2
    exit 1
fi
echo "▶ sim: $PAPERCUP_IOS_SIM_UDID"

xcrun simctl boot "$PAPERCUP_IOS_SIM_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$PAPERCUP_IOS_SIM_UDID" -b 2>/dev/null || true

if [ ! -d Papercup.xcodeproj ]; then
    xcodegen generate >/dev/null
fi

DEST="platform=iOS Simulator,id=$PAPERCUP_IOS_SIM_UDID"
DD="$PWD/build/dd"

# Build the app + test bundle target-by-target. Avoids the scheme's
# -destination resolution which is flaky under Xcode 16.2 + Sentry
# SwiftPM init. The build output lands in PROJECT_DIR/build/<config>-iphonesimulator
# by default when no -derivedDataPath is set.
PRODUCTS="$PWD/build/Debug-iphonesimulator"

echo "▶ build Papercup (app target = test host)"
xcodebuild -project Papercup.xcodeproj \
    -target Papercup \
    -sdk iphonesimulator \
    -destination "$DEST" \
    -configuration Debug \
    build

echo "▶ build PapercupTests"
xcodebuild -project Papercup.xcodeproj \
    -target PapercupTests \
    -sdk iphonesimulator \
    -destination "$DEST" \
    -configuration Debug \
    build

APP_BUNDLE="$PRODUCTS/Papercup.app"
# Test bundle gets embedded under the app's PlugIns directory.
TEST_BUNDLE="$APP_BUNDLE/PlugIns/PapercupTests.xctest"
if [ ! -d "$TEST_BUNDLE" ] || [ ! -d "$APP_BUNDLE" ]; then
    echo "ERROR: build outputs missing" >&2
    echo "  expected: $TEST_BUNDLE" >&2
    echo "  expected: $APP_BUNDLE" >&2
    ls -la "$PRODUCTS" >&2
    exit 1
fi

echo "▶ xcrun simctl install + xctest"
xcrun simctl install "$PAPERCUP_IOS_SIM_UDID" "$APP_BUNDLE"
xcrun simctl spawn "$PAPERCUP_IOS_SIM_UDID" xctest "$TEST_BUNDLE"

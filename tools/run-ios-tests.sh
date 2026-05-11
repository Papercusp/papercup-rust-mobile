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

# Build the test bundle. -target avoids the scheme's destination
# resolution which is flaky under Xcode 16.2 + Sentry SwiftPM init.
echo "▶ build PapercupTests"
xcodebuild -project Papercup.xcodeproj \
    -target PapercupTests \
    -sdk iphonesimulator \
    -destination "$DEST" \
    -configuration Debug \
    -derivedDataPath "$DD" \
    build

# Run the test bundle directly via xctest. The bundle lives in the
# DerivedData products dir after the build above.
TEST_BUNDLE="$DD/Build/Products/Debug-iphonesimulator/PapercupTests.xctest"
TEST_HOST="$DD/Build/Products/Debug-iphonesimulator/Papercup.app/Papercup"
if [ ! -d "$TEST_BUNDLE" ] || [ ! -f "$TEST_HOST" ]; then
    # PapercupTests has TEST_HOST=Papercup.app, so we also need the
    # app target built.
    echo "▶ build Papercup app target (test host)"
    xcodebuild -project Papercup.xcodeproj \
        -target Papercup \
        -sdk iphonesimulator \
        -destination "$DEST" \
        -configuration Debug \
        -derivedDataPath "$DD" \
        build
fi

# Use simctl to launch xctest inside the sim. This bypasses the
# scheme's build-for-testing entirely.
xcrun simctl install "$PAPERCUP_IOS_SIM_UDID" \
    "$DD/Build/Products/Debug-iphonesimulator/Papercup.app"

# xctest runner from the simulator's runtime
SIM_RUNTIME=$(xcrun simctl runtime list 2>/dev/null | awk '/iOS 18/ {print $NF; exit}')
if [ -z "$SIM_RUNTIME" ]; then
    SIM_RUNTIME=$(xcrun --sdk iphonesimulator --show-sdk-platform-path)
fi

echo "▶ xcrun simctl spawn ... xctest PapercupTests"
xcrun simctl spawn "$PAPERCUP_IOS_SIM_UDID" \
    xctest "$TEST_BUNDLE"

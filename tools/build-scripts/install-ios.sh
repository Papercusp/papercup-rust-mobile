#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build the iOS app + install + launch on the iPhone 16 simulator.
# Uses per-target build to dodge the Xcode 16.2 destination-resolver
# race that breaks `xcodebuild -scheme` since Sentry SwiftPM landed.
#
# Assumes ./build-ios.sh has already rebuilt PapercupCore.xcframework
# (or call `make build-ios install-ios`).
#
# PAPERCUP_IOS_SIM_UDID overrides the sim picker (first iPhone 16).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

# Skip xcodegen if the project already exists — regenerating wipes
# Xcode's destination cache and re-triggers the race.
if [ ! -d Papercup.xcodeproj ]; then
    xcodegen generate >/dev/null
fi

# Per-target build, NOT -scheme. -scheme trips the destination-
# resolver race; -target talks straight to the build system and
# uses the active SDK without iterating destinations.
echo "▶ building Papercup target (Debug, iphonesimulator)"
xcodebuild -project Papercup.xcodeproj -target Papercup \
    -sdk iphonesimulator -configuration Debug build \
    > build/install-ios.log 2>&1 || {
    echo "ERROR: build failed; tail of build/install-ios.log:" >&2
    tail -30 build/install-ios.log >&2
    exit 1
}

APP="$REPO_ROOT/ios/build/Debug-iphonesimulator/Papercup.app"
if [ ! -d "$APP" ]; then
    echo "ERROR: built app not at $APP" >&2
    exit 1
fi

BUNDLE_ID="com.papercuspai.operator.mobile"
echo "▶ installing $APP to sim"
xcrun simctl install "$PAPERCUP_IOS_SIM_UDID" "$APP"

echo "▶ launching $BUNDLE_ID"
xcrun simctl launch "$PAPERCUP_IOS_SIM_UDID" "$BUNDLE_ID"

echo "▶ done. Verify:"
echo "    bp=\$(xcrun simctl get_app_container $PAPERCUP_IOS_SIM_UDID $BUNDLE_ID)"
echo "    stat -f \"installed: %Sm\" \"\$bp/Papercup\""

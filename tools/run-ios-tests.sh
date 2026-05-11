#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run the iOS XCTest suite. Splits build-for-testing + test-without-
# building to dodge the Xcode 16.2 "iOS 18.2 not installed" destination
# resolver race; retries the build step up to 3x.
#
# PAPERCUP_IOS_SIM_UDID overrides the default sim picker (first
# available iPhone 16).

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

xcodegen generate >/dev/null

DEST="platform=iOS Simulator,id=$PAPERCUP_IOS_SIM_UDID"

for i in 1 2 3; do
    if xcodebuild build-for-testing \
        -project Papercup.xcodeproj -scheme Papercup \
        -destination "$DEST" -sdk iphonesimulator \
        -derivedDataPath build/dd 2>&1 | tail -3 | grep -q "TEST BUILD SUCCEEDED"; then
        break
    fi
    echo "[retry $i: destination race]"
    sleep 3
    if [ "$i" = "3" ]; then
        echo "ERROR: build-for-testing failed after 3 retries" >&2
        exit 1
    fi
done

xcodebuild test-without-building \
    -project Papercup.xcodeproj -scheme Papercup \
    -destination "$DEST" -derivedDataPath build/dd

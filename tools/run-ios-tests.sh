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

# The destination race resolves much more reliably when the sim is
# already booted before xcodebuild starts looking for destinations.
xcrun simctl boot "$PAPERCUP_IOS_SIM_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$PAPERCUP_IOS_SIM_UDID" -b 2>/dev/null || true

# Skip xcodegen if the project already exists — regenerating wipes
# Xcode's per-scheme destination cache and re-triggers the race.
if [ ! -d Papercup.xcodeproj ]; then
    xcodegen generate >/dev/null
fi

DEST="platform=iOS Simulator,id=$PAPERCUP_IOS_SIM_UDID"

for i in 1 2 3 4 5; do
    # `set -e` would kill us on a failed xcodebuild before we get to
    # check $? — disable it for the assignment, then re-enable.
    set +e
    out=$(xcodebuild build-for-testing \
        -project Papercup.xcodeproj -scheme Papercup \
        -destination "$DEST" -sdk iphonesimulator \
        -derivedDataPath build/dd 2>&1)
    rc=$?
    set -e
    if [ $rc -eq 0 ] && echo "$out" | grep -q "TEST BUILD SUCCEEDED"; then
        break
    fi
    echo "[build retry $i: destination race, rc=$rc]"
    sleep 5
    if [ "$i" = "5" ]; then
        echo "ERROR: build-for-testing failed after 5 retries (rc=$rc)" >&2
        echo "--- last 20 lines of xcodebuild output ---" >&2
        echo "$out" | tail -20 >&2
        exit 1
    fi
done

for i in 1 2 3 4 5; do
    set +e
    xcodebuild test-without-building \
        -project Papercup.xcodeproj -scheme Papercup \
        -destination "$DEST" -derivedDataPath build/dd
    rc=$?
    set -e
    if [ $rc -eq 0 ]; then
        exit 0
    fi
    echo "[test retry $i: rc=$rc]"
    sleep 5
done
echo "ERROR: test-without-building failed after 5 retries" >&2
exit 1

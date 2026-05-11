#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run the iOS XCUITest suite. Drives the real UI via XCUITest (taps
# real buttons, inspects real labels) — complements run-ios-tests.sh
# which runs unit tests.
#
# To exercise the paste-pair flow, mint a fresh pair token first and
# pass it via PAPERCUP_PAIR_PAYLOAD. Without it, only the fresh-launch
# smoke test runs (the paired flows XCTSkip themselves).
#
#   PAPERCUP_PAIR_PAYLOAD='{"server":"http://10.0.2.2:3060","pairToken":"...","workspaceId":"default"}'
#   ./tools/run-ios-uitests.sh
#
# PAPERCUP_IOS_SIM_UDID overrides the default sim picker.

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
echo "▶ paired-flow payload: $([ -n "${PAPERCUP_PAIR_PAYLOAD:-}" ] && echo present || echo absent)"

xcrun simctl boot "$PAPERCUP_IOS_SIM_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$PAPERCUP_IOS_SIM_UDID" -b 2>/dev/null || true

if [ ! -d Papercup.xcodeproj ]; then
    xcodegen generate >/dev/null
fi

DEST="platform=iOS Simulator,id=$PAPERCUP_IOS_SIM_UDID"

# Build the UI test bundle (same destination-race retry pattern).
for i in 1 2 3 4 5; do
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
    echo "[build retry $i: rc=$rc]"
    sleep 5
    if [ "$i" = "5" ]; then
        echo "ERROR: build-for-testing failed after 5 retries (rc=$rc)" >&2
        echo "$out" | tail -20 >&2
        exit 1
    fi
done

# test-without-building, scoped to the UI test bundle, with the pair
# payload threaded through TEST_RUNNER_* env vars (XCUITest forwards
# anything prefixed with TEST_RUNNER_ into the test process's env).
TEST_RUNNER_ENV=()
if [ -n "${PAPERCUP_PAIR_PAYLOAD:-}" ]; then
    TEST_RUNNER_ENV+=("TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD=$PAPERCUP_PAIR_PAYLOAD")
fi

for i in 1 2 3 4 5; do
    set +e
    env "${TEST_RUNNER_ENV[@]}" xcodebuild test-without-building \
        -project Papercup.xcodeproj -scheme Papercup \
        -destination "$DEST" \
        -only-testing PapercupUITests \
        -derivedDataPath build/dd
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

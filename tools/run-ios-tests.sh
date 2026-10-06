#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run the iOS XCTest unit suite (CI 'Test iOS app' via `make test-ios`).
# Splits build-for-testing + test-without-building to dodge the Xcode 16.2
# "iOS 18.2 not installed" destination resolver race, and retries each step
# up to 8x with 6s sleeps. The test step retries only an attempt in which
# no test executed, and passes only on result-bundle evidence. Tests:
# tools/tests/run-ios-tests-test.sh (`make test-ios-unit-runner`).
#
# After Sentry SwiftPM landed the destination race fires more often
# (Xcode spends more on package resolution per scheme invocation).
# Bigger retry budget here. The real fix is Xcode 16.3 which ships
# the matching SDK + sim runtime.
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

xcrun simctl boot "$PAPERCUP_IOS_SIM_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$PAPERCUP_IOS_SIM_UDID" -b 2>/dev/null || true

# Skip xcodegen if the project already exists — regenerating wipes
# Xcode's per-scheme destination cache and re-triggers the race.
if [ ! -d Papercup.xcodeproj ]; then
    xcodegen generate >/dev/null
fi

DEST="platform=iOS Simulator,id=$PAPERCUP_IOS_SIM_UDID"

for i in 1 2 3 4 5 6 7 8; do
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
    sleep 6
    if [ "$i" = "8" ]; then
        echo "ERROR: build-for-testing failed after 8 retries (rc=$rc)" >&2
        echo "$out" | tail -20 >&2
        exit 1
    fi
done

# Each attempt writes its own result bundle, and the shared guard
# (tools/build-scripts/check-xctest-summary.py, also used by
# run-ios-template-tests.sh) admits it only with nonzero passing tests,
# zero failures and zero skips. The destination race fails before any
# test runs, so only "xcodebuild failed and nothing executed" is retried.
# The following fail at once: executed tests that failed or skipped, an
# empty suite, a passing bundle with a failing xcodebuild, and a success
# with no readable result.
SUMMARY_GUARD="$REPO_ROOT/tools/build-scripts/check-xctest-summary.py"
mkdir -p build
for i in 1 2 3 4 5 6 7 8; do
    bundle="build/unit-$i.xcresult"
    summary="build/unit-$i-summary.json"
    rm -rf "$bundle" "$summary"
    set +e
    xcodebuild test-without-building \
        -project Papercup.xcodeproj -scheme Papercup \
        -destination "$DEST" -derivedDataPath build/dd \
        -only-testing PapercupTests -resultBundlePath "$bundle"
    rc=$?
    verdict=3
    if [ -d "$bundle" ] && xcrun xcresulttool get test-results summary \
            --path "$bundle" --format json > "$summary"; then
        python3 "$SUMMARY_GUARD" "$summary" PapercupTests
        verdict=$?
    fi
    set -e
    case "$verdict" in
        0)
            [ "$rc" -eq 0 ] && exit 0
            echo "ERROR: PapercupTests passed but xcodebuild exited $rc (attempt $i)" >&2
            exit 1
            ;;
        3)
            if [ "$rc" -eq 0 ]; then
                echo "ERROR: xcodebuild exited 0 but no PapercupTests test executed (attempt $i)" >&2
                exit 1
            fi
            ;;
        *)
            echo "ERROR: PapercupTests failed on attempt $i (xcodebuild rc=$rc); a real test failure is not retried" >&2
            exit 1
            ;;
    esac
    echo "[test retry $i: rc=$rc, no test executed]"
    [ "$i" = 8 ] || sleep 6
done
echo "ERROR: no PapercupTests test executed after 8 attempts (destination race)" >&2
exit 1

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Deterministic local-mac test entrypoint used through named host avis-imac.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-unit}"
case "$MODE" in
    build-only|unit|ui) ;;
    *) echo "Usage: $0 [build-only|unit|ui]" >&2; exit 2 ;;
esac

cd "$REPO_ROOT"
tools/build-scripts/check-ios-build-host-health.sh
tools/build-scripts/build-ios.sh
xcodegen generate --spec ios/project.yml

UDID="${PAPERCUP_IOS_SIM_UDID:-$(xcrun simctl list devices available | awk -F '[()]' '/iPhone.*\((Booted|Shutdown)\)/ { print $2; exit }')}"
[ -n "$UDID" ] || { echo "ERROR: simulator is unavailable" >&2; exit 2; }
xcrun simctl boot "$UDID" 2>/dev/null || true
simulator_ready=false
for _ in $(seq 1 60); do
    if xcrun simctl spawn "$UDID" launchctl print system >/dev/null 2>&1; then
        simulator_ready=true
        break
    fi
    sleep 1
done
[ "$simulator_ready" = true ] || {
    echo "ERROR: simulator did not become headless-ready within 60 seconds" >&2
    exit 2
}

DESTINATION="platform=iOS Simulator,id=$UDID"
DERIVED="$REPO_ROOT/ios/build/template-checks/derived-data"
BUILD_RESULT="$REPO_ROOT/ios/build/template-checks/build.xcresult"
rm -rf "$BUILD_RESULT"
xcodebuild build-for-testing \
    -project ios/Papercup.xcodeproj -scheme Papercup \
    -destination "$DESTINATION" -derivedDataPath "$DERIVED" \
    -resultBundlePath "$BUILD_RESULT"
[ "$MODE" = build-only ] && exit 0

BUNDLE=PapercupTests
[ "$MODE" = ui ] && BUNDLE=PapercupUITests
RESULT="$REPO_ROOT/ios/build/template-checks/$MODE.xcresult"
SUMMARY="$REPO_ROOT/ios/build/template-checks/$MODE-summary.json"
rm -rf "$RESULT"
TEST_RUNNER_ENV=()
if [ -n "${PAPERCUP_PAIR_PAYLOAD:-}" ]; then
    TEST_RUNNER_ENV+=("TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD=$PAPERCUP_PAIR_PAYLOAD")
fi
env ${TEST_RUNNER_ENV[@]+"${TEST_RUNNER_ENV[@]}"} xcodebuild test-without-building \
    -project ios/Papercup.xcodeproj -scheme Papercup \
    -destination "$DESTINATION" -derivedDataPath "$DERIVED" \
    -only-testing:"$BUNDLE" -resultBundlePath "$RESULT"
xcrun xcresulttool get test-results summary --path "$RESULT" --format json > "$SUMMARY"
python3 tools/build-scripts/check-xctest-summary.py "$SUMMARY" "$BUNDLE"

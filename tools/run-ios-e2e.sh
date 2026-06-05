#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Full iOS simulator E2E — the Brief 44 verify clause in one runner:
#
#   pair → Inbox live → chat round-trip → push deep-link
#
# Three phases (XCUITest can't shell out, so push delivery has to
# happen BETWEEN xcodebuild invocations):
#
#   A. PairFlowUITests/testPairAndPairedNavigation — pairs via the
#      launch-arg backdoor (one-shot token), grants notification
#      permission, drives Settings nav + Inbox live fetch + a chat
#      round-trip on the shared operator thread.
#   B. `xcrun simctl push` delivers an APNS payload with an attention
#      `kind` while the app is terminated (real APNS can't reach a
#      simulator at all — simctl IS the canonical sim delivery path;
#      the cloud half of push is covered by the Android FCM e2e).
#   C. PairFlowUITests/testPushTapDeepLink — opens Notification
#      Center, taps the notification, asserts the cold-launched app
#      deep-links to the Inbox tab.
#
# Required:
#   PAPERCUP_PAIR_PAYLOAD  — {"server","pairToken","workspaceId"} JSON,
#                            freshly minted (one-shot).
# Optional:
#   PAPERCUP_IOS_SIM_UDID  — simulator override (default: first iPhone 16).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/ios"

BUNDLE_ID=com.papercuspai.operator.mobile

if [ -z "${PAPERCUP_PAIR_PAYLOAD:-}" ]; then
    echo "ERROR: PAPERCUP_PAIR_PAYLOAD required (mint via POST /api/device/desktop/mint-pair-token)" >&2
    exit 1
fi

if [ -z "${PAPERCUP_IOS_SIM_UDID:-}" ]; then
    PAPERCUP_IOS_SIM_UDID=$(xcrun simctl list devices available \
        | awk -F '[()]' '/iPhone 16 \(/{print $2; exit}')
fi
[ -n "$PAPERCUP_IOS_SIM_UDID" ] || { echo "ERROR: no iPhone 16 sim" >&2; exit 1; }
echo "▶ sim: $PAPERCUP_IOS_SIM_UDID"

xcrun simctl boot "$PAPERCUP_IOS_SIM_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$PAPERCUP_IOS_SIM_UDID" -b 2>/dev/null || true

[ -d Papercup.xcodeproj ] || xcodegen generate >/dev/null

DEST="platform=iOS Simulator,id=$PAPERCUP_IOS_SIM_UDID"

echo "▶ build-for-testing"
xcodebuild build-for-testing \
    -project Papercup.xcodeproj -scheme Papercup \
    -destination "$DEST" -sdk iphonesimulator \
    -derivedDataPath build/dd | tail -2

echo "▶ phase A: pair + Inbox live + chat round-trip"
env "TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD=$PAPERCUP_PAIR_PAYLOAD" \
    xcodebuild test-without-building \
    -project Papercup.xcodeproj -scheme Papercup -destination "$DEST" \
    -only-testing PapercupUITests/PairFlowUITests/testPairAndPairedNavigation \
    -derivedDataPath build/dd

echo "▶ phase B: deliver APNS payload via simctl push (app terminated)"
xcrun simctl terminate "$PAPERCUP_IOS_SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
PUSH_JSON=$(mktemp /tmp/papercup-push-XXXX.json)
cat > "$PUSH_JSON" <<'EOF'
{
  "aps": {
    "alert": {
      "title": "Papercusp E2E",
      "body": "A work item needs you — tap to open the Inbox."
    },
    "sound": "default"
  },
  "kind": "needs-human"
}
EOF
xcrun simctl push "$PAPERCUP_IOS_SIM_UDID" "$BUNDLE_ID" "$PUSH_JSON"
rm -f "$PUSH_JSON"
sleep 3

echo "▶ phase C: notification tap → Inbox deep-link"
env "TEST_RUNNER_PAPERCUP_PUSH_TAP_PHASE=1" \
    xcodebuild test-without-building \
    -project Papercup.xcodeproj -scheme Papercup -destination "$DEST" \
    -only-testing PapercupUITests/PairFlowUITests/testPushTapDeepLink \
    -derivedDataPath build/dd

echo "✅ iOS E2E complete: pair → Inbox live → chat round-trip → push deep-link"

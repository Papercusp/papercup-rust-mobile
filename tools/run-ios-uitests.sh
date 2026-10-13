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
#   PAPERCUP_PAIR_PAYLOAD='{"server":"http://10.0.2.2:3055","pairToken":"...","workspaceId":"default"}'
# (3055 is the operator dev server / TypeScript backend; 3070 is prod TS.
#  Do NOT point the example at the Rust port :3060 — the mobile app only
#  uses the TypeScript backend; Rust is opt-in via ?backend=rust on the
#  desktop only.)
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
mkdir -p build
for i in 1 2 3 4 5; do
    build_log="build/build-for-testing-ui-$i.log"
    set +e
    xcodebuild build-for-testing \
        -project Papercup.xcodeproj -scheme Papercup \
        -destination "$DEST" -sdk iphonesimulator \
        -derivedDataPath build/dd > "$build_log" 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] && grep -q "TEST BUILD SUCCEEDED" "$build_log"; then
        break
    fi
    echo "[build failure $i: rc=$rc; log: $build_log]" >&2
    tail -80 "$build_log" >&2
    # Only the measured SDK destination-resolver race is retryable.
    # Compile, package and missing-success failures must stop immediately.
    if [ "$rc" -eq 0 ] || ! grep -Eq 'iOS [0-9]+(\.[0-9]+)* is not installed' "$build_log"; then
        echo "ERROR: build-for-testing failed; not a retryable destination race (rc=$rc)" >&2
        exit 1
    fi
    if [ "$i" = "5" ]; then
        echo "ERROR: build-for-testing failed after 5 destination-race attempts (rc=$rc)" >&2
        exit 1
    fi
    sleep 5
done

# test-without-building, scoped to the UI test bundle, with the pair
# payload threaded through TEST_RUNNER_* env vars (XCUITest forwards
# anything prefixed with TEST_RUNNER_ into the test process's env).
#
# One-shot pair-token discipline (WI-4985): mobile_pair_tokens are
# consumed on FIRST use, so re-running the paired suite with the SAME
# payload can never pass — attempt 1 spends the token and attempts 2-5
# then fail at "Operator tab should appear", masquerading as app flake.
# Two supported shapes:
#   • PAPERCUP_MINT_PAIR_PAYLOAD_CMD — a shell command that prints a
#     FRESH pair payload JSON on stdout; invoked before EVERY attempt,
#     enabling safe retries.
#   • static PAPERCUP_PAIR_PAYLOAD only — the paired suite runs exactly
#     ONCE (the runner refuses to burn dead attempts on a spent token).
# No payload at all ⇒ only idempotent smoke tests run; retries are safe.
MAX_ATTEMPTS=5
if [ -n "${PAPERCUP_PAIR_PAYLOAD:-}" ] && [ -z "${PAPERCUP_MINT_PAIR_PAYLOAD_CMD:-}" ]; then
    echo "▶ static one-shot pair payload: paired suite runs ONCE, no retries (WI-4985)"
    MAX_ATTEMPTS=1
fi

attempt=0
while [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    if [ -n "${PAPERCUP_MINT_PAIR_PAYLOAD_CMD:-}" ]; then
        PAPERCUP_PAIR_PAYLOAD="$(bash -c "$PAPERCUP_MINT_PAIR_PAYLOAD_CMD")"
        if [ -z "$PAPERCUP_PAIR_PAYLOAD" ]; then
            echo "ERROR: PAPERCUP_MINT_PAIR_PAYLOAD_CMD printed an empty payload" >&2
            exit 1
        fi
        echo "▶ minted fresh pair payload for attempt $attempt"
    fi
    TEST_RUNNER_ENV=()
    if [ -n "${PAPERCUP_PAIR_PAYLOAD:-}" ]; then
        TEST_RUNNER_ENV+=("TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD=$PAPERCUP_PAIR_PAYLOAD")
    fi
    # Voice-parity soak (WI-5091): forward the fixture dir + turn count so
    # VoiceParityUITests un-skips and the app-side inject hook engages.
    if [ -n "${PAPERCUP_UITEST_VOICE_PCM_DIR:-}" ]; then
        TEST_RUNNER_ENV+=("TEST_RUNNER_PAPERCUP_UITEST_VOICE_PCM_DIR=$PAPERCUP_UITEST_VOICE_PCM_DIR")
    fi
    if [ -n "${PAPERCUP_UITEST_VOICE_TURNS:-}" ]; then
        TEST_RUNNER_ENV+=("TEST_RUNNER_PAPERCUP_UITEST_VOICE_TURNS=$PAPERCUP_UITEST_VOICE_TURNS")
    fi
    # PAPERCUP_UITEST_ONLY narrows to one class/test (e.g.
    # "VoiceParityUITests") — REQUIRED when a one-shot pair payload must
    # not be spent by the other paired tests in the bundle (WI-5091).
    ONLY_TARGET="PapercupUITests${PAPERCUP_UITEST_ONLY:+/$PAPERCUP_UITEST_ONLY}"
    set +e
    TEST_OUT="$(mktemp -t papercup-uitest-out)"
    env ${TEST_RUNNER_ENV[@]+"${TEST_RUNNER_ENV[@]}"} xcodebuild test-without-building \
        -project Papercup.xcodeproj -scheme Papercup \
        -destination "$DEST" \
        -only-testing "$ONLY_TARGET" \
        -derivedDataPath build/dd 2>&1 | tee "$TEST_OUT"
    rc=${PIPESTATUS[0]}
    set -e
    if [ "$rc" -eq 0 ]; then
        rm -f "$TEST_OUT"
        exit 0
    fi
    # A test-runner BOOTSTRAP crash ("operation never finished bootstrapping",
    # a sim warm-up flake) exits 65 without ever launching the app — the
    # one-shot pair payload was NOT spent, so one retry is safe even in the
    # static-payload ONCE mode (WI-5091 round 13). Caution when grading from
    # this script's exit code alone: Xcode has been seen recovering the
    # session AFTER the rc=65 and re-running the suite green, detached —
    # trust the result artifacts (xcresult / per-turn result JSONs).
    if [ "$MAX_ATTEMPTS" -eq 1 ] && [ "$attempt" -eq 1 ] \
        && grep -q "never finished bootstrapping" "$TEST_OUT"; then
        echo "▶ bootstrap crash before app launch — payload unspent, granting one retry"
        MAX_ATTEMPTS=2
    fi
    rm -f "$TEST_OUT"
    echo "[test retry $attempt: rc=$rc]"
    sleep 5
done
echo "ERROR: test-without-building failed after $MAX_ATTEMPTS attempt(s)" >&2
exit 1

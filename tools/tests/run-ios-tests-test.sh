#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Exercise tools/run-ios-tests.sh (CI 'Test iOS app' via `make test-ios`) without
# a Mac. Stubbed xcodebuild/xcrun play one scripted outcome per attempt; the
# runner must retry only the destination race (xcodebuild failed and no test
# executed), fail a real test failure at once, and pass only on result-bundle
# evidence of nonzero passing tests with zero failures and zero skips.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/tools/build-scripts" "$TEST_ROOT/ios/Papercup.xcodeproj" "$TEST_ROOT/bin"
cp "$REPO_ROOT/tools/run-ios-tests.sh" "$TEST_ROOT/tools/"
cp "$REPO_ROOT/tools/build-scripts/check-xctest-summary.py" "$TEST_ROOT/tools/build-scripts/"
TEST_STATE="$TEST_ROOT/state"

# No real sleeping between attempts, and xcodegen must not regenerate an existing project.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/bin/sleep"
printf '#!/usr/bin/env bash\necho "xcodegen must not run" >&2\nexit 9\n' > "$TEST_ROOT/bin/xcodegen"

# Each test-without-building call consumes the next "<rc> <summary-json|->" line
# of $TEST_STATE/plan. "-" leaves no result bundle, like the destination race.
cat > "$TEST_ROOT/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
if [ "$1" = build-for-testing ]; then
    echo '** TEST BUILD SUCCEEDED **'
    exit 0
fi
[ "$1" = test-without-building ] || { echo "unexpected xcodebuild $1" >&2; exit 2; }
bundle=
while [ $# -gt 0 ]; do
    if [ "$1" = -resultBundlePath ]; then bundle="$2"; fi
    shift
done
[ -n "$bundle" ] || { echo 'runner must pass -resultBundlePath' >&2; exit 2; }
attempt=$(( $(wc -l < "$TEST_STATE/attempts") + 1 ))
echo "$bundle" >> "$TEST_STATE/attempts"
spec="$(sed -n "${attempt}p" "$TEST_STATE/plan")"
[ -n "$spec" ] || { echo "no scripted outcome for attempt $attempt" >&2; exit 2; }
rc="${spec%% *}"
summary="${spec#* }"
if [ "$summary" != - ]; then
    mkdir -p "$bundle"
    printf '%s\n' "$summary" > "$bundle/summary.json"
fi
exit "$rc"
SH

cat > "$TEST_ROOT/bin/xcrun" <<'SH'
#!/usr/bin/env bash
case "$1" in
    simctl) exit 0 ;;
    xcresulttool)
        [ "$2 $3 $4" = 'get test-results summary' ] || {
            echo 'runner must request the execution summary' >&2; exit 2;
        }
        path=
        while [ $# -gt 0 ]; do
            if [ "$1" = --path ]; then path="$2"; fi
            shift
        done
        cat "$path/summary.json"
        ;;
    *) echo "unexpected xcrun $1" >&2; exit 2 ;;
esac
SH
chmod +x "$TEST_ROOT/bin/"*

PASS='{"passedTests":3,"failedTests":0,"skippedTests":0}'
FAILED='{"passedTests":2,"failedTests":1,"skippedTests":0}'
SKIPPED='{"passedTests":2,"failedTests":0,"skippedTests":1}'
EMPTY='{"passedTests":0,"failedTests":0,"skippedTests":0}'
NO_COUNTS='{"nodeIdentifier":"suite"}'
RACE8=('70 -' '70 -' '70 -' '70 -' '70 -' '70 -' '70 -' '70 -')
passed=0

run_plan() {
    rm -rf "$TEST_ROOT/ios/build" "$TEST_STATE"
    mkdir -p "$TEST_STATE"
    : > "$TEST_STATE/attempts"
    printf '%s\n' "$@" > "$TEST_STATE/plan"
    if [ -n "${STALE_PASSING_BUNDLES:-}" ]; then
        for i in 1 2 3 4 5 6 7 8; do
            mkdir -p "$TEST_ROOT/ios/build/unit-$i.xcresult"
            printf '%s\n' "$PASS" > "$TEST_ROOT/ios/build/unit-$i.xcresult/summary.json"
        done
    fi
    PATH="$TEST_ROOT/bin:$PATH" PAPERCUP_IOS_SIM_UDID=test-simulator TEST_STATE="$TEST_STATE" \
        bash "$TEST_ROOT/tools/run-ios-tests.sh" > "$TEST_ROOT/output" 2>&1
}

attempts() { wc -l < "$TEST_STATE/attempts" | tr -d ' '; }

fail() {
    cat "$TEST_ROOT/output" >&2
    echo "FAIL: $1" >&2
    exit 1
}

expect_pass() {
    local name="$1" want="$2"
    shift 2
    run_plan "$@" || fail "$name was rejected"
    [ "$(attempts)" = "$want" ] || fail "$name ran $(attempts) attempts, expected $want"
    grep -F 'Executed 3 passing tests' "$TEST_ROOT/output" >/dev/null || fail "$name passed without the guard"
    passed=$((passed + 1))
}

expect_fail() {
    local name="$1" want="$2" message="$3"
    shift 3
    if run_plan "$@"; then fail "$name was accepted"; fi
    [ "$(attempts)" = "$want" ] || fail "$name ran $(attempts) attempts, expected $want"
    grep -F -- "$message" "$TEST_ROOT/output" >/dev/null || fail "$name failed without '$message'"
    passed=$((passed + 1))
}

expect_pass 'first-attempt pass' 1 "0 $PASS"
expect_pass 'race without a bundle, then pass' 2 '70 -' "0 $PASS"
[ "$(tr '\n' ' ' < "$TEST_STATE/attempts")" = 'build/unit-1.xcresult build/unit-2.xcresult ' ] \
    || fail 'each attempt must write its own result bundle'
expect_pass 'race with an empty bundle, then pass' 2 "70 $EMPTY" "0 $PASS"
expect_fail 'executed failure' 1 'a real test failure is not retried' "65 $FAILED" "0 $PASS"
expect_fail 'failure despite xcodebuild success' 1 'requires nonzero passing tests' "0 $FAILED"
expect_fail 'skipped test' 1 'a real test failure is not retried' "0 $SKIPPED"
expect_fail 'empty suite with xcodebuild success' 1 'no PapercupTests test executed (attempt 1)' "0 $EMPTY"
expect_fail 'missing counts with xcodebuild success' 1 'no PapercupTests test executed (attempt 1)' "0 $NO_COUNTS"
expect_fail 'xcodebuild success without a result bundle' 1 'no PapercupTests test executed (attempt 1)' '0 -'
expect_fail 'passing bundle with failing xcodebuild' 1 'passed but xcodebuild exited 65' "65 $PASS"
expect_fail 'persistent destination race' 8 'after 8 attempts' "${RACE8[@]}"
STALE_PASSING_BUNDLES=1 expect_fail 'stale passing bundles from an earlier run' 8 'after 8 attempts' "${RACE8[@]}"
echo "iOS unit runner tests: $passed passed"

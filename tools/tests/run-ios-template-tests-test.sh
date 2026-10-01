#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Exercise native result admission through the maintained runner, without a Mac.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/tools/build-scripts" "$TEST_ROOT/ios/build/template-checks" "$TEST_ROOT/bin"
cp "$REPO_ROOT/tools/run-ios-template-tests.sh" "$TEST_ROOT/tools/"
for script in check-ios-build-host-health build-ios; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/tools/build-scripts/$script.sh"
    chmod +x "$TEST_ROOT/tools/build-scripts/$script.sh"
done
for command in xcodegen xcodebuild; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/bin/$command"
    chmod +x "$TEST_ROOT/bin/$command"
done
cat > "$TEST_ROOT/bin/xcrun" <<'SH'
#!/usr/bin/env bash
if [ "$1" = xcresulttool ]; then
    [ "$4" = summary ] || { echo 'runner must request execution summary, not tree nodes' >&2; exit 2; }
    printf '%s\n' "$TEST_NATIVE_SUMMARY"
fi
SH
chmod +x "$TEST_ROOT/bin/xcrun"
run_summary() {
    PATH="$TEST_ROOT/bin:$PATH" PAPERCUP_IOS_SIM_UDID=test-simulator \
        TEST_NATIVE_SUMMARY="$1" bash "$TEST_ROOT/tools/run-ios-template-tests.sh" unit
}
expect_rejected() {
    if run_summary "$1" > "$TEST_ROOT/output" 2>&1; then
        echo "FAIL: $2 was accepted" >&2; exit 1
    fi
    grep -F 'requires nonzero passing tests' "$TEST_ROOT/output" >/dev/null || {
        cat "$TEST_ROOT/output" >&2; echo "FAIL: $2 failed outside the result guard" >&2; exit 1;
    }
}
run_summary '{"passedTests":2,"failedTests":0,"skippedTests":0}' > "$TEST_ROOT/output"
grep -F 'Executed 2 passing tests' "$TEST_ROOT/output" >/dev/null
expect_rejected '{"passedTests":0,"failedTests":0,"skippedTests":1,"nodeIdentifier":"skipped-case"}' 'skipped-only bundle'
expect_rejected '{"passedTests":0,"failedTests":0,"skippedTests":0,"nodeIdentifier":"empty-suite"}' 'empty suite'
expect_rejected '{"passedTests":1,"failedTests":1,"skippedTests":0}' 'test failure despite successful executor'
expect_rejected '{"passedTests":1,"failedTests":0,"skippedTests":1}' 'partially skipped bundle'
expect_rejected '{"nodeIdentifier":"suite"}' 'missing execution counts'
echo 'iOS template runner tests: 6 passed'

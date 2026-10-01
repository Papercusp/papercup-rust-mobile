#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
runner="$ROOT/tools/run-android-checks.sh"
mkdir -p "$TMP_ROOT/test-results/testDebugUnitTest" "$TMP_ROOT/test-results/testReleaseUnitTest" \
    "$TMP_ROOT/outputs/androidTest-results/connected/debug/device"
debug="$TMP_ROOT/test-results/testDebugUnitTest/TEST-unit.xml"
release="$TMP_ROOT/test-results/testReleaseUnitTest/TEST-unit.xml"
native="$TMP_ROOT/outputs/androidTest-results/connected/debug/device/TEST-native.xml"
good='<testsuite tests="1"><testcase name="actuallyRan"/></testsuite>'
printf '%s' "$good" > "$debug"
printf '%s' "$good" > "$release"
printf '%s' "$good" > "$native"
bash "$runner" verify-results "$TMP_ROOT" host
bash "$runner" verify-results "$TMP_ROOT" connected
for bad in '<testsuite tests="0"/>' \
    '<testsuite tests="1"><testcase name="skipped"><skipped/></testcase></testsuite>' \
    '<testsuite tests="1"><testcase name="failed"><failure/></testcase></testsuite>' \
    '<testsuite tests="1"><testcase name="errored"><error/></testcase></testsuite>' \
    '<testsuite tests="1" failures="1"><testcase name="missingFailureBody"/></testsuite>' \
    '<testsuite tests="1" skipped="1"><testcase name="missingSkipBody"/></testsuite>' \
    'invalid XML'; do
    printf '%s' "$bad" > "$release"
    if bash "$runner" verify-results "$TMP_ROOT" host > "$TMP_ROOT/output" 2>&1; then
        echo "FAIL: invalid or unexecuted test report accepted: $bad" >&2
        exit 1
    fi
done
rm "$native"
if bash "$runner" verify-results "$TMP_ROOT" connected > "$TMP_ROOT/output" 2>&1; then
    echo 'FAIL: missing instrumentation result was accepted' >&2
    exit 1
fi
echo 'Android result guard tests: 10 passed'

# The CI preparation phase must refuse a real developer/self-hosted machine.
if GITHUB_ACTIONS=false RUNNER_ENVIRONMENT=github-hosted bash "$runner" prepare-ci > "$TMP_ROOT/output" 2>&1; then
    echo 'FAIL: CI cleanup admitted a developer host' >&2
    exit 1
fi
if GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=self-hosted bash "$runner" prepare-ci > "$TMP_ROOT/output" 2>&1; then
    echo 'FAIL: CI cleanup admitted a self-hosted runner' >&2
    exit 1
fi

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/sdk/ndk/26.0.1" "$TMP_ROOT/sdk/ndk/27.0.12077973"
cat > "$TMP_ROOT/bin/cargo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_CI_COMMAND_LOG"
SH
cat > "$TMP_ROOT/bin/sdkmanager" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_CI_COMMAND_LOG"
SH
chmod +x "$TMP_ROOT/bin/cargo" "$TMP_ROOT/bin/sdkmanager"
GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted ANDROID_HOME="$TMP_ROOT/sdk" \
    TEST_CI_COMMAND_LOG="$TMP_ROOT/ci-commands" PATH="$TMP_ROOT/bin:$PATH" bash "$runner" prepare-ci "$TMP_ROOT/attempt"
[[ "$(grep -c '^clean --release --target ' "$TMP_ROOT/ci-commands")" == 4 ]]
for target in aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android; do
    grep -Fxq "clean --release --target $target" "$TMP_ROOT/ci-commands"
done
grep -Fq -- '--uninstall ndk;26.0.1' "$TMP_ROOT/ci-commands"
if grep -Fq 'ndk;27.0.12077973' "$TMP_ROOT/ci-commands"; then
    echo 'FAIL: CI cleanup removed the pinned NDK' >&2
    exit 1
fi
[[ -d "$TMP_ROOT/sdk/ndk/27.0.12077973" ]]
[[ -s "$TMP_ROOT/attempt/storage.txt" ]]
echo 'Android CI working-set guards: host refusals, four target-only cleans and pinned NDK preservation passed'

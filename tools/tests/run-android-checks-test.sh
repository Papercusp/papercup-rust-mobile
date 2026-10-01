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

# Full cleanup is admitted only after executed host tests and a preserved APK.
mkdir -p "$TMP_ROOT/outputs/apk/debug"
printf '%s' "$good" > "$release"
printf 'built APK fixture' > "$TMP_ROOT/outputs/apk/debug/app-debug.apk"
GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted ANDROID_HOME="$TMP_ROOT/sdk" \
    TEST_CI_COMMAND_LOG="$TMP_ROOT/after-host-commands" PATH="$TMP_ROOT/bin:$PATH" \
    bash "$runner" prepare-ci "$TMP_ROOT/after-host-attempt" after-host "$TMP_ROOT"
grep -Fxq clean "$TMP_ROOT/after-host-commands"
for missing in report apk; do
    if [[ "$missing" == report ]]; then
        printf '<testsuite tests="0"/>' > "$release"
    else
        printf '%s' "$good" > "$release"
        rm "$TMP_ROOT/outputs/apk/debug/app-debug.apk"
    fi
    if GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted ANDROID_HOME="$TMP_ROOT/sdk" \
        TEST_CI_COMMAND_LOG="$TMP_ROOT/refused-cleanup-$missing" PATH="$TMP_ROOT/bin:$PATH" \
        bash "$runner" prepare-ci "$TMP_ROOT/after-host-attempt" after-host "$TMP_ROOT" > "$TMP_ROOT/output" 2>&1; then
        echo "FAIL: after-host cleanup accepted missing $missing" >&2
        exit 1
    fi
    [[ ! -e "$TMP_ROOT/refused-cleanup-$missing" ]]
done
echo 'Android after-host cleanup guards: executed reports and preserved APK required'

# Reproduce the hosted counterexample without consuming a real disk: the
# retained attempt had 6,405,476 KiB free, insufficient for default userdata.
# Check the real runner's capacity decision and retained diagnostic evidence.
cat > "$TMP_ROOT/bin/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/test 75085112 0 %s 0%% /test\n' "${TEST_CI_AVAILABLE_KB:-6405476}"
SH
chmod +x "$TMP_ROOT/bin/df"
TEST_CI_AVAILABLE_KB=10485760 ANDROID_AVD_HOME="$TMP_ROOT/avd with spaces" PATH="$TMP_ROOT/bin:$PATH" \
    bash "$runner" verify-avd-space 6144M "$TMP_ROOT/avd-space-proof"
grep -Fq '"sufficient": true' "$TMP_ROOT/avd-space-proof/avd-space.txt"
if ANDROID_AVD_HOME="$TMP_ROOT/avd with spaces" PATH="$TMP_ROOT/bin:$PATH" \
    bash "$runner" verify-avd-space 2048M "$TMP_ROOT/undersized-avd-space-proof" > "$TMP_ROOT/output" 2>&1; then
    echo 'FAIL: a 2-GiB request hid the effective 6-GiB capacity failure' >&2
    exit 1
fi
grep -Fq '"configuredPartitionBytes": 2147483648' "$TMP_ROOT/undersized-avd-space-proof/avd-space.txt"
grep -Fq '"partitionBytes": 6442450944' "$TMP_ROOT/undersized-avd-space-proof/avd-space.txt"
if ANDROID_AVD_HOME="$TMP_ROOT/avd with spaces" PATH="$TMP_ROOT/bin:$PATH" \
    bash "$runner" verify-avd-space 6144M "$TMP_ROOT/default-avd-space-proof" > "$TMP_ROOT/output" 2>&1; then
    echo 'FAIL: the measured default-userdata capacity failure was accepted' >&2
    exit 1
fi
grep -Fq '"sufficient": false' "$TMP_ROOT/default-avd-space-proof/avd-space.txt"
if TEST_CI_AVAILABLE_KB=1024 ANDROID_AVD_HOME="$TMP_ROOT/avd with spaces" PATH="$TMP_ROOT/bin:$PATH" \
    bash "$runner" verify-avd-space 2048M "$TMP_ROOT/low-avd-space-proof" > "$TMP_ROOT/output" 2>&1; then
    echo 'FAIL: insufficient space for the configured userdata was accepted' >&2
    exit 1
fi
grep -Fq 'Insufficient space' "$TMP_ROOT/output"
for invalid in 0 2GB -1 ''; do
    if ANDROID_AVD_HOME="$TMP_ROOT/avd with spaces" PATH="$TMP_ROOT/bin:$PATH" \
        bash "$runner" verify-avd-space "$invalid" "$TMP_ROOT/invalid-avd-space-proof" > "$TMP_ROOT/output" 2>&1; then
        echo "FAIL: invalid AVD disk-size was accepted: $invalid" >&2
        exit 1
    fi
done
echo 'Android AVD capacity guards: effective minimum enforced; adequate space accepted; low-space and invalid inputs rejected'

mkdir -p "$TMP_ROOT/sdk/emulator/qemu/linux-x86_64"
cat > "$TMP_ROOT/sdk/emulator/emulator" <<'SH'
#!/usr/bin/env bash
[[ "${TEST_EMULATOR_FAIL:-0}" == 0 ]] || exit 127
echo 'Android emulator test version'
SH
cat > "$TMP_ROOT/sdk/emulator/qemu/linux-x86_64/qemu-system-x86_64" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$TMP_ROOT/bin/ldd" <<'SH'
#!/usr/bin/env bash
if [[ "${TEST_EMULATOR_MISSING_LIB:-0}" == 1 ]]; then
    echo 'libpulse.so.0 => not found'
else
    echo 'libpulse.so.0 => /test/libpulse.so.0'
fi
SH
chmod +x "$TMP_ROOT/sdk/emulator/emulator" "$TMP_ROOT/sdk/emulator/qemu/linux-x86_64/qemu-system-x86_64" "$TMP_ROOT/bin/ldd"
ANDROID_HOME="$TMP_ROOT/sdk" PATH="$TMP_ROOT/bin:$PATH" bash "$runner" verify-emulator "$TMP_ROOT/emulator-proof"
[[ -s "$TMP_ROOT/emulator-proof/emulator-version.txt" ]]
if TEST_EMULATOR_MISSING_LIB=1 ANDROID_HOME="$TMP_ROOT/sdk" PATH="$TMP_ROOT/bin:$PATH" bash "$runner" verify-emulator "$TMP_ROOT/missing-lib-proof" > "$TMP_ROOT/output" 2>&1; then
    echo 'FAIL: missing emulator shared library was accepted' >&2
    exit 1
fi
grep -Fq 'libpulse.so.0 => not found' "$TMP_ROOT/missing-lib-proof/emulator-libraries.txt"
if TEST_EMULATOR_FAIL=1 ANDROID_HOME="$TMP_ROOT/sdk" PATH="$TMP_ROOT/bin:$PATH" bash "$runner" verify-emulator "$TMP_ROOT/failed-emulator-proof" > "$TMP_ROOT/output" 2>&1; then
    echo 'FAIL: failed emulator executable was accepted' >&2
    exit 1
fi
echo 'Android emulator preflight guards: working executable accepted; missing library and failed executable rejected'

# Use the real ELF loader to distinguish missing host dependencies from SDK
# libraries that the emulator launcher adds to its search path. No RPATH is
# linked into this fixture, so a bare ldd must report the bundled libraries missing.
if [[ "$(uname -s)" == Linux ]]; then
    real_sdk="$TMP_ROOT/real sdk"
    core_lib="$real_sdk/emulator/lib64"
    qt_lib="$core_lib/qt/lib"
    extra_lib="$TMP_ROOT/inherited libs"
    mkdir -p "$core_lib" "$qt_lib" "$extra_lib" "$real_sdk/emulator/qemu/linux-x86_64"
    printf 'int android_guard_core(void) { return 1; }\n' | cc -x c -fPIC -shared - -o "$core_lib/libandroid_guard_core.so"
    printf 'int android_guard_qt(void) { return 2; }\n' | cc -x c -fPIC -shared - -o "$qt_lib/libandroid_guard_qt.so"
    printf 'int android_guard_inherited(void) { return 3; }\n' | cc -x c -fPIC -shared - -o "$extra_lib/libandroid_guard_inherited.so"
    real_qemu="$real_sdk/emulator/qemu/linux-x86_64/qemu-system-x86_64"
    cc -x c - -L"$core_lib" -L"$qt_lib" -L"$extra_lib" \
        -landroid_guard_core -landroid_guard_qt -landroid_guard_inherited -o "$real_qemu" <<'C'
int android_guard_core(void);
int android_guard_qt(void);
int android_guard_inherited(void);
int main(void) {
    return android_guard_core() + android_guard_qt() + android_guard_inherited() == 6 ? 0 : 1;
}
C
    cp "$TMP_ROOT/sdk/emulator/emulator" "$real_sdk/emulator/emulator"
    ldd "$real_qemu" > "$TMP_ROOT/bare-loader.txt"
    grep -Fq 'libandroid_guard_core.so => not found' "$TMP_ROOT/bare-loader.txt"
    grep -Fq 'libandroid_guard_qt.so => not found' "$TMP_ROOT/bare-loader.txt"
    LD_LIBRARY_PATH="$extra_lib" ANDROID_HOME="$real_sdk" \
        bash "$runner" verify-emulator "$TMP_ROOT/real-loader-proof"
    if grep -Fq 'not found' "$TMP_ROOT/real-loader-proof/emulator-libraries.txt"; then
        echo 'FAIL: bundled or inherited emulator library was rejected' >&2
        exit 1
    fi
    rm "$core_lib/libandroid_guard_core.so"
    if LD_LIBRARY_PATH="$extra_lib" ANDROID_HOME="$real_sdk" \
        bash "$runner" verify-emulator "$TMP_ROOT/real-missing-library-proof" > "$TMP_ROOT/output" 2>&1; then
        echo 'FAIL: a genuinely missing ELF dependency was accepted' >&2
        exit 1
    fi
    grep -Fq 'libandroid_guard_core.so => not found' "$TMP_ROOT/real-missing-library-proof/emulator-libraries.txt"
    echo 'Android emulator real-loader guards: bundled and inherited libraries accepted; missing dependency rejected'
fi

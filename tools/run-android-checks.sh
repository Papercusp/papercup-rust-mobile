#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Reuse the maintained Rust, build, privacy and installer checks. A green
# Gradle exit with zero, skipped or stale test results is not a verified run.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

verify_results() {
    python3 - "$1" "$2" <<'PY'
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

root, mode = Path(sys.argv[1]), sys.argv[2]
groups = ['test-results/testDebugUnitTest', 'test-results/testReleaseUnitTest'] if mode == 'host' else ['outputs/androidTest-results/connected/debug']
for group in groups:
    files = list((root / group).rglob('TEST-*.xml'))
    if not files:
        raise SystemExit(f'No executed Android tests in {group}')
    count = 0
    for file in files:
        tree = ET.parse(file).getroot()
        cases = list(tree.iter('testcase'))
        if not cases:
            raise SystemExit(f'Empty Android test report: {file}')
        for suite in tree.iter('testsuite'):
            if any(int(suite.get(tag, '0')) for tag in ('failures', 'errors', 'skipped')):
                raise SystemExit(f'Android suite reports failures or skips: {file}')
        for case in cases:
            if any(case.find(tag) is not None for tag in ('failure', 'error', 'skipped')):
                raise SystemExit(f'Android test did not pass: {file}: {case.get("name")}')
        count += len(cases)
    print(f'Android {group}: {count} executed, zero failed or skipped')
PY
}

mode="${1:-full}"
if [[ "$mode" == verify-avd-space ]]; then
    partition="${2:?explicit AVD disk-size is required}"
    avd_root="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
    attempt_dir="${3:-android-ci-attempt}"
    mkdir -p "$avd_root" "$attempt_dir"
    available_kb="$(df -Pk "$avd_root" | awk 'NR == 2 { print $4 }')"
    # The selected API 36/16-KB runtime allocated 6 GiB even after the action
    # requested 2048M (run 36927827065). A requested size is not an effective
    # allocation. Cover that measured minimum as well as larger requests.
    # The emulator reserves 20% beyond the effective userdata partition.
    # Keep another GiB for installed APKs, test output and emulator writes.
    python3 - "$partition" "$available_kb" "$avd_root" <<'PY' | tee -a "$attempt_dir/avd-space.txt"
import json
import re
import sys

match = re.fullmatch(r'([1-9][0-9]*)([KMG]?)', sys.argv[1])
if not match or not sys.argv[2].isdigit():
    raise SystemExit('AVD space preflight requires a positive disk-size and measured free space')
configured = int(match[1]) * {'': 1, 'K': 1024, 'M': 1024**2, 'G': 1024**3}[match[2]]
partition = max(configured, 6 * 1024**3)
available = int(sys.argv[2]) * 1024
required = (partition * 6 + 4) // 5 + 1024**3
print(json.dumps({'avdRoot': sys.argv[3], 'configuredPartitionBytes': configured,
                  'partitionBytes': partition,
                  'availableBytes': available, 'requiredBytes': required,
                  'sufficient': available >= required}))
if available < required:
    raise SystemExit('Insufficient space for the effective AVD userdata partition and test working set')
PY
    exit
fi
if [[ "$mode" == verify-emulator ]]; then
    [[ -n "${ANDROID_HOME:-}" ]] || exit 2
    attempt_dir="${2:-android-ci-attempt}"
    mkdir -p "$attempt_dir"
    qemu="$ANDROID_HOME/emulator/qemu/linux-x86_64/qemu-system-x86_64"
    [[ -x "$qemu" && -x "$ANDROID_HOME/emulator/emulator" ]] || {
        echo 'Android emulator executable is missing.' >&2
        exit 1
    }
    # The SDK launcher adds bundled core and Qt libraries before execing QEMU.
    # Match that environment for ldd; probing the engine directly otherwise
    # misclassifies a complete SDK as missing its own shared libraries.
    LD_LIBRARY_PATH="$ANDROID_HOME/emulator/lib64:$ANDROID_HOME/emulator/lib64/qt/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        ldd "$qemu" > "$attempt_dir/emulator-libraries.txt" 2>&1 || {
        cat "$attempt_dir/emulator-libraries.txt" >&2
        exit 1
    }
    if grep -Fq 'not found' "$attempt_dir/emulator-libraries.txt"; then
        echo 'Android emulator shared-library dependencies are missing:' >&2
        cat "$attempt_dir/emulator-libraries.txt" >&2
        exit 1
    fi
    "$ANDROID_HOME/emulator/emulator" -version > "$attempt_dir/emulator-version.txt" 2>&1
    exit
fi
if [[ "$mode" == prepare-ci ]]; then
    # Only the disposable, owned Actions runner may prune its toolchain.
    [[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || {
        echo 'CI working-set preparation requires a GitHub-hosted runner.' >&2
        exit 2
    }
    [[ -n "${ANDROID_HOME:-}" && -d "$ANDROID_HOME/ndk" ]] || {
        echo 'CI working-set preparation requires the installed Android SDK.' >&2
        exit 2
    }
    attempt_dir="${2:-android-ci-attempt}"
    stage="${3:-before-host}"
    case "$stage" in
        before-host|after-host) ;;
        *) echo 'CI preparation stage must be before-host or after-host.' >&2; exit 2 ;;
    esac
    mkdir -p "$attempt_dir"
    {
        date -u +%FT%TZ
        df -Pk . "$ANDROID_HOME"
        du -sk "${CARGO_TARGET_DIR:-target}" "$ANDROID_HOME/ndk" 2>/dev/null || true
    } >> "$attempt_dir/storage.txt"
    if [[ "$stage" == after-host ]]; then
        build_root="${4:-android/app/build}"
        # Native execution consumes the built APK and Gradle outputs, not Cargo
        # intermediates. Refuse full cleanup until real host reports and the APK
        # exist. This branch is restricted to the disposable hosted runner above.
        verify_results "$build_root" host
        [[ -s "$build_root/outputs/apk/debug/app-debug.apk" ]] || {
            echo 'After-host cleanup requires the built debug APK.' >&2
            exit 1
        }
        cargo clean
    else
        # Keep host bindgen/test outputs until their checks have executed.
        for target in aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android; do
            cargo clean --release --target "$target"
        done
    fi
    for ndk in "$ANDROID_HOME"/ndk/*; do
        [[ -d "$ndk" ]] || continue
        revision="${ndk##*/}"
        [[ "$revision" == 27.0.12077973 ]] && continue
        sdkmanager "--sdk_root=$ANDROID_HOME" --uninstall "ndk;$revision"
    done
    df -Pk . "$ANDROID_HOME" >> "$attempt_dir/storage.txt"
    exit
fi
if [[ "$mode" == verify-results ]]; then
    [[ "${3:-}" == host || "${3:-}" == connected ]] || exit 2
    verify_results "$2" "$3"
    exit
fi
[[ "$mode" == host || "$mode" == connected || "$mode" == full ]] || {
    echo 'usage: run-android-checks.sh [host|connected|full|prepare-ci|verify-emulator|verify-avd-space DISK_SIZE|verify-results ROOT host|connected]' >&2
    exit 2
}

JAVA_HOME="$(tools/build-scripts/resolve-java-home.sh)"
export JAVA_HOME
ANDROID_HOME="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"
ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_HOME ANDROID_SDK_ROOT
export PATH="$ANDROID_HOME/platform-tools:$PATH"

if [[ "$mode" != connected ]]; then
    cargo fmt --all -- --check
    cargo clippy --workspace --all-targets -- -D warnings
    cargo test --workspace --all-targets
    make bindings-smoke test-android-java test-android-launch-lifecycle \
        test-android-release-provenance test-android-signing test-android-runner test-android-ci
    # build-android.sh verifies all four packaged ABIs, UniFFI checksums and
    # 16 KB ELF/ZIP alignment; it deliberately does not launch a device.
    make bindings-kotlin
    bash tools/build-scripts/build-android.sh debug
    rm -rf android/app/build/test-results/testDebugUnitTest \
        android/app/build/test-results/testReleaseUnitTest
    android/gradlew -p android :app:testDebugUnitTest :app:testReleaseUnitTest \
        :app:lintRelease --rerun-tasks
    bash tools/tests/android-privacy-permissions-test.sh
    verify_results android/app/build host
fi

if [[ "$mode" != host ]]; then
    mapfile -t devices < <(adb devices | awk 'NR>1 && $2=="device"{print $1}')
    [[ ${#devices[@]} == 1 ]] || {
        echo 'Android native gate requires exactly one connected test device.' >&2
        exit 1
    }
    device="${devices[0]}"
    [[ "$(adb -s "$device" shell getprop sys.boot_completed | tr -d '\r')" == 1 ]]
    [[ "$(adb -s "$device" shell getprop ro.build.version.sdk | tr -d '\r')" == 36 ]]
    [[ "$(adb -s "$device" shell getconf PAGE_SIZE | tr -d '\r')" == 16384 ]]
    adb -s "$device" shell pm path android | grep -q '^package:'
    bash tools/build-scripts/install-and-launch.sh
    rm -rf android/app/build/outputs/androidTest-results/connected/debug
    ANDROID_SERIAL="$device" android/gradlew -p android :app:connectedDebugAndroidTest --rerun-tasks
    verify_results android/app/build connected
fi

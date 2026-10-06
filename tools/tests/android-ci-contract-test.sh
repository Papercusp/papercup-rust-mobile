#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# This is a reachability guard: managed skip-ci commits must still reach the
# complete native check, and failed runs must never create a success marker.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "${1:-$ROOT/.github/workflows/ci.yml}" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
assert '  schedule:' in text, 'managed skip-ci commits have no automatic CI route'
android = text.split('\n  android:\n', 1)[1].split('\n  ios:\n', 1)[0]
assert 'make check-android-host' in android
assert 'secrets.PAPERCUP_ANDROID_GOOGLE_SERVICES_JSON' in android, 'existing Firebase app configuration is not injected'
assert 'bash tools/run-android-checks.sh connected' in android
assert 'PAPERCUP_OPERATOR_SHA:' in android and '${{ env.PAPERCUP_OPERATOR_SHA }}' in android, 'paired CI needs an exact pinned operator counterpart'
import re
assert re.search(r'PAPERCUP_OPERATOR_SHA: [0-9a-f]{40}\n', android), 'operator counterpart must be an immutable commit'
assert 'token: ${{ secrets.SUBMODULES_PAT }}' in android and 'submodules: recursive' in android, 'root-only deploy key cannot obtain private operator dependencies'
assert 'test -n "$SUBMODULES_PAT"' in android, 'private dependency access must fail before expensive setup'
assert android.index('Require private operator dependency access') < android.index('Restore exact-content native success proof')
assert 'node-version: 25' in android, 'actual operator native dependencies require Node25'
assert 'node scripts/npm-install-safe.mjs ci --legacy-peer-deps' in android and 'bash apps/operator/bin/bundle-host.sh' in android, 'reuse canonical dependency and host builders'
assert "PAPERCUSP_SKIP_DEP_GENERATION: '1'" in android, 'a one-shot runner cannot hold the shared-tree dependency generation snapshot (exit 77)'
assert 'node apps/operator/bin/bundle-host-freshness.mjs check' in android, 'stale counterpart bundle must be refused'
assert 'PAPERCUSP_BUNDLE_REUSE_FRESH=1 bash apps/operator/bin/bundle-host.sh' in android, 'freshness validation requires the canonical builder to stamp its manifest'
assert 'emulator-port: 5554' in android and 'ANDROID_SERIAL=emulator-5554 bash tools/run-android-checks.sh isolated-native android-ci-attempt/operator android-ci-attempt/paired' in android, 'automatic native leg must execute the owned paired journey'
assert android.count('bash tools/run-android-checks.sh verify-isolated-native') == 2, 'fresh and cached paired proof must be validated'
assert 'android-api36-16k-paired-v2-${{ env.PAPERCUP_OPERATOR_SHA }}-' in android, 'counterpart changes must invalidate old success'
assert 'cp -r android-ci-attempt/paired android-ci-proof/paired' in android
assert 'cp -r android-ci-attempt/paired-runtime android-ci-proof/paired-runtime' in android
assert 'android-ci-attempt/unpaired-native-results' in android, 'original fixture-free coverage must survive paired execution'
assert '\n            android-ci-attempt/operator\n' not in android and '\n            android-ci-attempt\n' not in android, 'do not archive the private source/dependency checkout'
assert 'api-level: 36' in android and 'target: google_apis_ps16k' in android
assert '-gpu swiftshader ' in android and 'swiftshader_indirect' not in android, 'use the supported software renderer, not the retired indirect mode'
assert '-feature GLDirectMem,HasSharedSlotsHostMemoryAllocator ' in android, 'new Goldfish mappers require both host DMA readback capabilities'
assert android.count('bash tools/run-android-checks.sh prepare-ci') == 2, 'CI must bound the working set before SDK setup and before native execution'
image = "'system-images;android-36;google_apis_ps16k;x86_64'"
assert image in android and android.index(image) < android.index('make check-android-host'), 'system-image precondition must run before the expensive build'
assert 'ANDROID_NDK_HOME=$ANDROID_HOME/ndk/27.0.12077973' in android, 'runner default NDK must not override the pinned toolchain'
assert 'android-ci-attempt/apk-sha256.txt' in android, 'failed native attempts must identify the tested APK'
assert 'apt-get install --no-install-recommends -y libpulse0' in android, 'QEMU needs the PulseAudio shared library'
assert "sdkmanager 'emulator'" in android, 'emulator must be installed before executable preflight'
preflight = 'bash tools/run-android-checks.sh verify-emulator'
assert android.count(preflight) == 2 and android.index(preflight) < android.index('make check-android-host'), 'emulator loader precondition must run before the expensive build'
late_cleanup = 'bash tools/run-android-checks.sh prepare-ci android-ci-attempt after-host'
assert late_cleanup in android and android.index('make check-android-host') < android.index(late_cleanup) < android.index('uses: reactivecircus/android-emulator-runner@v2'), 'full intermediate cleanup must follow verified host checks and precede native execution'
space_preflight = 'bash tools/run-android-checks.sh verify-avd-space 6144M'
assert '          disk-size: 6144M\n' in android, 'AVD userdata demand must cover the measured effective 6-GiB allocation'
assert android.count(space_preflight) == 3 and android.index(space_preflight) < android.index('make check-android-host'), 'AVD capacity must be checked before host build, native setup and launch'
assert f'          pre-emulator-launch-script: {space_preflight}\n' in android, 'AVD capacity must be rechecked after AVD creation'
sdk_setup = android.split('uses: android-actions/setup-android@v3', 1)[1].split('\n      -', 1)[0]
assert '          packages: platform-tools\n' in sdk_setup, 'SDK bootstrap must not request the retired tools package'
assert '          mkdir -p android-ci-attempt\n' in android, 'bootstrap failures need source-bound attempt evidence'
assert '\n            android-ci-attempt/*.txt\n' in android, 'early failure evidence must be retained'
for path in ['android/**', 'crates/**', 'Cargo.toml', 'Cargo.lock', 'tools/**', 'Makefile', 'checks-config.json', '.github/workflows/ci.yml']:
    assert f"'{path}'" in android, f'{path} changes can reuse stale CI success'
assert 'uses: actions/cache/save@v4' in android
save = android.split('uses: actions/cache/save@v4', 1)[0].rsplit('- name:', 1)[1]
assert "if: success() && steps.android-proof.outputs.cache-hit != 'true'" in save
assert 'restore-keys:' not in android, 'partial-key proof must never skip native verification'
assert 'if-no-files-found: error' in android, 'native proof is required'
for apk in ['android/app/build/outputs/apk/debug/app-debug.apk', 'android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk']:
    assert f'            {apk}\n' in android, f'tested APK bytes must survive native failure: {apk}'
    assert f'          cp {apk} android-ci-proof/apks/\n' in android, f'cached native proof must retain tested APK bytes: {apk}'
print('Android CI reachability contract: passed')
PY

python3 - "${2:-$ROOT/tools/run-android-checks.sh}" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
assert 'set -euo pipefail' in text, 'failed Android checks must stop verification'
host = text.split('if [[ "$mode" != connected ]]; then', 1)[1].split('\nfi\n', 1)[0]
connected = text.split('if [[ "$mode" != host ]]; then', 1)[1].split('\nfi\n', 1)[0]
for phase in [
    'cargo fmt --all -- --check',
    'cargo clippy --workspace --all-targets -- -D warnings',
    'cargo test --workspace --all-targets',
    'make bindings-smoke test-android-java test-android-launch-lifecycle',
    'test-android-release-provenance',
    'test-android-signing',
    'test-android-library-notices',
    'test-android-runner',
    'test-android-ci',
    'make bindings-kotlin',
    'bash tools/build-scripts/build-android.sh debug',
    ':app:testDebugUnitTest :app:testReleaseUnitTest',
    ':app:lintRelease --rerun-tasks',
    'bash tools/tests/android-privacy-permissions-test.sh',
    'verify_results android/app/build host',
]:
    assert phase in host, f'Android host runner omits required phase: {phase}'
for phase in [
    'bash tools/build-scripts/install-and-launch.sh',
    'bash "$0" verify-emulator-boot "$device"',
    ':app:connectedDebugAndroidTest --rerun-tasks',
    'verify_results android/app/build connected',
]:
    assert phase in connected, f'Android native runner omits required phase: {phase}'
print('Android CI required host/native phase contract: passed')
PY

if [[ $# == 0 ]]; then
    TMP_ROOT="$(mktemp -d)"
    trap 'rm -rf "$TMP_ROOT"' EXIT
    python3 - "$ROOT/.github/workflows/ci.yml" "$TMP_ROOT" <<'PY'
import re
import sys
from pathlib import Path
text, out = Path(sys.argv[1]).read_text(), Path(sys.argv[2])
(out / 'retired-sdk.yml').write_text(text.replace('          packages: platform-tools\n', '          packages: tools platform-tools\n'))
(out / 'retired-renderer.yml').write_text(text.replace('-gpu swiftshader ', '-gpu swiftshader_indirect '))
(out / 'missing-dma-direct.yml').write_text(text.replace('GLDirectMem,HasSharedSlotsHostMemoryAllocator', 'HasSharedSlotsHostMemoryAllocator'))
(out / 'missing-dma-allocator.yml').write_text(text.replace('GLDirectMem,HasSharedSlotsHostMemoryAllocator', 'GLDirectMem'))
(out / 'missing-early-evidence.yml').write_text(text.replace('          mkdir -p android-ci-attempt\n', ''))
(out / 'floating-operator.yml').write_text(re.sub(r'PAPERCUP_OPERATOR_SHA: [0-9a-f]{40}', 'PAPERCUP_OPERATOR_SHA: staging', text))
(out / 'missing-submodule-access.yml').write_text(text.replace('          token: ${{ secrets.SUBMODULES_PAT }}\n', ''))
(out / 'missing-operator-preflight.yml').write_text(text.replace('          test -n "$SUBMODULES_PAT"', '          test -n "unused"'))
(out / 'missing-submodules.yml').write_text(text.replace('          submodules: recursive\n', ''))
(out / 'wrong-operator-node.yml').write_text(text.replace('          node-version: 25\n', '          node-version: 22\n'))
(out / 'missing-safe-install.yml').write_text(text.replace('node scripts/npm-install-safe.mjs ci --legacy-peer-deps', ': omitted'))
(out / 'missing-host-builder.yml').write_text(text.replace('bash apps/operator/bin/bundle-host.sh', ': omitted'))
(out / 'missing-host-freshness-stamp.yml').write_text(text.replace('PAPERCUSP_BUNDLE_REUSE_FRESH=1 ', ''))
(out / 'missing-host-freshness.yml').write_text(text.replace('node apps/operator/bin/bundle-host-freshness.mjs check', ': omitted'))
(out / 'unpaired-only.yml').write_text(text.replace('ANDROID_SERIAL=emulator-5554 bash tools/run-android-checks.sh isolated-native android-ci-attempt/operator android-ci-attempt/paired', ': omitted'))
(out / 'missing-paired-validation.yml').write_text(text.replace('bash tools/run-android-checks.sh verify-isolated-native', ': omitted'))
(out / 'unbound-paired-cache.yml').write_text(text.replace('android-api36-16k-paired-v2-${{ env.PAPERCUP_OPERATOR_SHA }}-', 'android-api36-16k-v1-'))
(out / 'missing-paired-proof.yml').write_text(text.replace('          cp -r android-ci-attempt/paired android-ci-proof/paired\n', ''))
(out / 'missing-paired-runtime.yml').write_text(text.replace('          cp -r android-ci-attempt/paired-runtime android-ci-proof/paired-runtime\n', ''))
(out / 'missing-unpaired-proof.yml').write_text(text.replace('android-ci-attempt/unpaired-native-results', 'omitted-results'))
(out / 'upload-operator-checkout.yml').write_text(text.replace('            android-ci-attempt/*.txt\n', '            android-ci-attempt\n'))
(out / 'missing-working-set.yml').write_text(text.replace('          bash tools/run-android-checks.sh prepare-ci\n', ''))
(out / 'late-image.yml').write_text(text.replace(" 'system-images;android-36;google_apis_ps16k;x86_64'", ''))
(out / 'missing-emulator-libs.yml').write_text(text.replace('libpulse0', 'disabled-libpulse'))
(out / 'missing-emulator-preflight.yml').write_text(text.replace('          bash tools/run-android-checks.sh verify-emulator\n', ''))
(out / 'default-avd-disk.yml').write_text(text.replace('          disk-size: 6144M\n', ''))
(out / 'undersized-avd-disk.yml').write_text(text.replace('          disk-size: 6144M\n', '          disk-size: 2048M\n'))
(out / 'oversized-avd-disk.yml').write_text(text.replace('          disk-size: 6144M\n', '          disk-size: 8192M\n'))
(out / 'missing-avd-space.yml').write_text(text.replace('          bash tools/run-android-checks.sh verify-avd-space 6144M\n', ''))
(out / 'missing-avd-launch-space.yml').write_text(text.replace('          pre-emulator-launch-script: bash tools/run-android-checks.sh verify-avd-space 6144M\n', ''))
(out / 'missing-after-host-cleanup.yml').write_text(text.replace(' prepare-ci android-ci-attempt after-host', ' prepare-ci'))
for name, apk in [('app', 'android/app/build/outputs/apk/debug/app-debug.apk'), ('instrumentation', 'android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk')]:
    (out / f'missing-{name}-apk.yml').write_text(text.replace(f'            {apk}\n', ''))
    (out / f'missing-cached-{name}-apk.yml').write_text(text.replace(f'          cp {apk} android-ci-proof/apks/\n', ''))
PY
    for fixture in "$TMP_ROOT"/*.yml; do
        if bash "$0" "$fixture" > "$TMP_ROOT/output" 2>&1; then
            echo "FAIL: CI regression accepted: $fixture" >&2
            exit 1
        fi
    done
    echo 'Android CI bootstrap/storage/emulator/paired-provenance mutation controls: 35 rejected'

    # A workflow invoking "host" is insufficient if the owned runner stops
    # executing one of its required phases. Keep each omission reproducible.
    python3 - "$ROOT/tools/run-android-checks.sh" "$TMP_ROOT" <<'PY'
import sys
from pathlib import Path
text, out = Path(sys.argv[1]).read_text(), Path(sys.argv[2])
phases = [
    'cargo fmt --all -- --check',
    'cargo clippy --workspace --all-targets -- -D warnings',
    'cargo test --workspace --all-targets',
    'make bindings-smoke test-android-java test-android-launch-lifecycle',
    'test-android-release-provenance',
    'test-android-signing',
    'test-android-library-notices',
    'test-android-runner',
    'test-android-ci',
    'make bindings-kotlin',
    'bash tools/build-scripts/build-android.sh debug',
    ':app:testDebugUnitTest :app:testReleaseUnitTest',
    ':app:lintRelease --rerun-tasks',
    'bash tools/tests/android-privacy-permissions-test.sh',
    'verify_results android/app/build host',
    'bash tools/build-scripts/install-and-launch.sh',
    'bash "$0" verify-emulator-boot "$device"',
    ':app:connectedDebugAndroidTest --rerun-tasks',
    'verify_results android/app/build connected',
    'set -euo pipefail',
]
for index, phase in enumerate(phases):
    assert phase in text, f'positive runner phase missing: {phase}'
    (out / f'runner-{index}.sh').write_text(text.replace(phase, ': omitted-phase'))
PY
    for fixture in "$TMP_ROOT"/runner-*.sh; do
        if bash "$0" "$ROOT/.github/workflows/ci.yml" "$fixture" > "$TMP_ROOT/output" 2>&1; then
            echo "FAIL: omitted Android runner phase accepted: $fixture" >&2
            exit 1
        fi
    done
    echo 'Android CI runner phase mutation controls: 20 rejected'
fi

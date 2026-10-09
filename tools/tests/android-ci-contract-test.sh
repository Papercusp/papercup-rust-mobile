#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Independent CI must reach every maintained gate and fail closed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_FILE="$ROOT/tools/android-ci.py"
if (( $# > 0 )); then CI_FILE="$1"; fi
python3 - "$CI_FILE" "$ROOT" <<'PY'
import re, sys
from pathlib import Path
text, root = Path(sys.argv[1]).read_text(), Path(sys.argv[2])
workflow_path = root / '.github/workflows/ci.yml'
# iPhone migration retires the final workflow too. The omission guards still
# reject restored Android jobs, while an intentionally absent file is valid.
workflow = workflow_path.read_text() if workflow_path.exists() else ''
for job in ('android', 'rust', 'uniffi-bindings', 'design-tokens'):
    assert not re.search(r'^  ' + job + r':', workflow, re.M), 'Android/shared job remains on Actions: ' + job
assert '  schedule:' not in workflow, 'Android Actions schedule remains'
for call in ("run_phase('host'", "run_phase('connected'", "run_phase('paired'", "run_phase('verify-paired'"):
    assert call in text, 'independent CI omits gate: ' + call
for contract in ('check-android-host', 'tokens-check', 'isolated-native', 'features',
                 'verify-isolated-native', 'source_identity(root) != identity',
                 "if result['status'] == 'passed':",
                 'bundle-host-freshness.mjs', 'collect_artifacts(root, attempt)',
                 'fcntl.LOCK_EX | fcntl.LOCK_NB', 'emulator.terminate()', 'emulator.wait(timeout=15)',
                 'swiftshader', 'GLDirectMem,HasSharedSlotsHostMemoryAllocator', "'4096'", "'6144'",
                 "env['ANDROID_SERIAL']", 'system-images;android-36;google_apis_ps16k;x86_64'):
    assert contract in text, 'independent CI contract missing: ' + contract
service = (root / 'tools/ci/papercusp-android-ci.service').read_text()
timer = (root / 'tools/ci/papercusp-android-ci.timer').read_text()
assert 'tools/android-ci.py' in service and 'KillMode=control-group' in service
assert 'EnvironmentFile=-%h/.config/papercusp/android-ci.env' in service
assert 'OnUnitInactiveSec=30min' in timer and 'WantedBy=timers.target' in timer
assert 'GitHub' not in service
assert "def inherited_executor(" in text and "--exclusive-command" in text
for relative in ('tools/build-scripts/build-android.sh', 'tools/run-android-checks.sh',
                 'tools/cloud-native-check.py'):
    writer = (root / relative).read_text()
    assert '--exclusive-command' in writer and '--verify-executor' in writer, \
        'maintained output writer omits shared executor custody: ' + relative
ignore = (root / '.gitignore').read_text()
assert '__pycache__/' in ignore and '*.py[co]' in ignore, \
    'runtime Python bytecode must not dirty the source-change CI identity'
print('Independent Android CI trigger/ownership/admission contract: passed')
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
    'bash "$0" verify-native-dependencies',
    'bash tools/build-scripts/install-and-launch.sh',
    'bash "$0" verify-emulator-boot "$device"',
    'ANDROID_SERIAL="$device" bash "$0" sealed-native',
    'verify_results android/app/build connected',
]:
    assert phase in connected, f'Android native runner omits required phase: {phase}'
print('Android CI required host/native phase contract: passed')
sealed = text.split('if [[ "$mode" == sealed-native ]]; then', 1)[1].split('\nfi\n', 1)[0]
assert "':app:connectedDebugAndroidTest'" in sealed
assert "command.append('--rerun-tasks')" in sealed, 'full native gate must rerun rather than trust old reports'
assert 'SealedTransportInteropTest' in sealed and "len(cases) != 2" in sealed, 'real JNI interop must execute both cases'
assert "'reverse', '--remove'" in sealed and 'child.terminate()' in sealed, 'owned interop fixture must clean up'
assert "'verify-native-dependencies'], check=True" in text, 'paired native must reject stale Espresso before build'
PY

python3 - "${3:-$ROOT/Makefile}" <<'PY'
import sys
from pathlib import Path
make = Path(sys.argv[1]).read_text()
target = make.split('\ncheck-android-paired:\n', 1)
assert len(target) == 2, 'local path must expose the paired native journey CI runs'
recipe = target[1].split('\n\n', 1)[0]
assert 'bash tools/run-android-checks.sh isolated-native "$(PAPERCUP_OPERATOR_DIR)"' in recipe, 'local paired target must execute the isolated journey'
assert 'bash tools/run-android-checks.sh verify-isolated-native "$(ANDROID_PAIRED_EVIDENCE)"' in recipe, 'local paired target must validate proof like CI'
assert recipe.index('isolated-native "$(') < recipe.index('verify-isolated-native'), 'validation must follow execution'
print('Android local paired target contract: passed')
PY

if [[ $# == 0 ]]; then
    TMP_ROOT="$(mktemp -d)"
    trap 'rm -rf "$TMP_ROOT"' EXIT
    python3 - "$ROOT/tools/android-ci.py" "$TMP_ROOT" <<'PY'
from pathlib import Path
import sys
text, out = Path(sys.argv[1]).read_text(), Path(sys.argv[2])
for i, needle in enumerate(("run_phase('host'", "run_phase('connected'", "run_phase('paired'",
                           "run_phase('verify-paired'", 'source_identity(root) != identity',
                           'bundle-host-freshness.mjs', 'emulator.terminate()',
                           "env['ANDROID_SERIAL']", 'collect_artifacts(root, attempt)')):
    assert needle in text
    (out / f'ci-{i}.py').write_text(text.replace(needle,'omitted-contract'))
PY
    for fixture in "$TMP_ROOT"/ci-*.py; do
        if bash "$0" "$fixture" > "$TMP_ROOT/output" 2>&1; then
            echo "FAIL: independent CI omission accepted: $fixture" >&2
            exit 1
        fi
    done
    echo 'Independent Android CI omission controls: 9 rejected'
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
    'bash "$0" verify-native-dependencies',
    'bash tools/build-scripts/install-and-launch.sh',
    'bash "$0" verify-emulator-boot "$device"',
    'ANDROID_SERIAL="$device" bash "$0" sealed-native',
    'verify_results android/app/build connected',
    'set -euo pipefail',
]
for index, phase in enumerate(phases):
    assert phase in text, f'positive runner phase missing: {phase}'
    (out / f'runner-{index}.sh').write_text(text.replace(phase, ': omitted-phase'))
PY
    for fixture in "$TMP_ROOT"/runner-*.sh; do
        if bash "$0" "$ROOT/tools/android-ci.py" "$fixture" > "$TMP_ROOT/output" 2>&1; then
            echo "FAIL: omitted Android runner phase accepted: $fixture" >&2
            exit 1
        fi
    done
    echo 'Android CI runner phase mutation controls: 21 rejected'

    python3 - "$ROOT/Makefile" "$TMP_ROOT" <<'PY'
import sys
from pathlib import Path
text, out = Path(sys.argv[1]).read_text(), Path(sys.argv[2])
run = 'bash tools/run-android-checks.sh isolated-native "$(PAPERCUP_OPERATOR_DIR)"'
check = 'bash tools/run-android-checks.sh verify-isolated-native "$(ANDROID_PAIRED_EVIDENCE)"'
for needle in ('\ncheck-android-paired:\n', run, check):
    assert needle in text, f'positive Makefile contract missing: {needle!r}'
(out / 'make-missing-target.mk').write_text(text.replace('\ncheck-android-paired:\n', '\ncheck-android-unpaired:\n'))
(out / 'make-missing-run.mk').write_text(text.replace(run, ': omitted'))
(out / 'make-missing-check.mk').write_text(text.replace(check, ': omitted'))
PY
    for fixture in "$TMP_ROOT"/make-*.mk; do
        if bash "$0" "$ROOT/tools/android-ci.py" "$ROOT/tools/run-android-checks.sh" "$fixture" > "$TMP_ROOT/output" 2>&1; then
            echo "FAIL: local paired target regression accepted: $fixture" >&2
            exit 1
        fi
    done
    echo 'Android local paired target mutation controls: 3 rejected'
fi

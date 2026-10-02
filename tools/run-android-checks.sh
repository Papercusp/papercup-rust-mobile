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
if [[ "$mode" == live ]]; then
    # Reuse the canonical Cargo smoke, with owned fixtures rather than a
    # manually registered second workspace that disappears between sessions.
    python3 - "${2:-}" "${3:-rust}" <<'PY'
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import shutil
import shlex
import xml.etree.ElementTree as ET
import urllib.parse
import urllib.request
from urllib.error import HTTPError
import uuid

kind = sys.argv[2]
if kind not in ('rust', 'native'):
    raise SystemExit('live check kind must be rust or native')
base = os.environ.get('PAPERCUP_LIVE_BASE', '').rstrip('/')
url = urllib.parse.urlsplit(base)
if (url.scheme != 'http' or url.hostname not in ('127.0.0.1', 'localhost', '::1')
        or url.path or url.query or url.fragment or url.username or url.password):
    raise SystemExit('live checks require an explicit loopback PAPERCUP_LIVE_BASE')
timeout = int(os.environ.get('PAPERCUP_LIVE_TIMEOUT_SEC', '240'))
if not 1 <= timeout <= 600:
    raise SystemExit('live timeout must be between 1 and 600 seconds')
attempt = uuid.uuid4().hex
out = Path(sys.argv[1] or f'android/app/build/ci-evidence/live-{attempt}')
out.mkdir(parents=True, exist_ok=False, mode=0o700)
log_path = out / ('native-test.log' if kind == 'native' else 'cargo-test.log')

def api(path, method='GET', body=None):
    request = urllib.request.Request(base + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)

def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

before = api('/api/workspaces')
workspace = os.environ.get('PAPERCUP_LIVE_WORKSPACE', before.get('current'))
existing = {row['id'] for row in before['workspaces']}
if not before.get('current') or workspace not in existing:
    raise SystemExit('live checks require an existing workspace and current selection')
fixture_name = f'android-live-scope-{attempt}'
command = ['cargo', 'test', '-p', 'papercup-core', '--test', 'live_smoke',
           'live_p0_contract_smoke', '--', '--ignored', '--nocapture']
result = {'command': command, 'startedAt': now(), 'runtime': base,
          'runId': attempt, 'checkKind': kind, 'ownedWorkspace': None, 'ownedDeviceIds': [],
          'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
          'sourceDirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True)),
          'sourceFingerprints': {path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
              for path in ['tools/run-android-checks.sh', 'crates/papercup-core/tests/live_smoke.rs']},
          'scope': ('Owned local debug native pairing/JNI/navigation with external browser intent fixture; no signed-candidate, mesh, phone or Play acceptance'
                    if kind == 'native' else 'Rust API contract on current operator; no native or release-candidate acceptance'),
          'log': str(log_path), 'exitCode': 1, 'cleanupVerified': False}
fixture_id = None
token = None
errors = []
native_device = None
native_payload_created = False
native_execution_started = False
reverse_created = False
existing_devices = set()
app = 'com.papercuspai.operator.mobile'
connected = Path('android/app/build/outputs/androidTest-results/connected/debug')

def adb(*args, input=None, check=True):
    return subprocess.run(['adb', '-s', native_device, *args], input=input,
        capture_output=True, text=True, check=check, timeout=30)

def app_shell(command, **kwargs):
    return adb('shell', 'run-as ' + app + ' sh -c ' + shlex.quote(command), **kwargs)

def prepare_native():
    global native_device
    devices = subprocess.check_output(['adb', 'devices'], text=True)
    serials = [line.split()[0] for line in devices.splitlines()[1:]
               if len(line.split()) == 2 and line.split()[1] == 'device']
    requested = os.environ.get('ANDROID_SERIAL')
    if (len(serials) != 1 or not serials[0].startswith('emulator-')
            or not requested or requested != serials[0]):
        raise RuntimeError('native live checks require exactly one explicitly owned emulator')
    native_device = serials[0]
    for args, expected in [(('shell', 'getprop', 'sys.boot_completed'), '1'),
                           (('shell', 'getprop', 'ro.build.version.sdk'), '36'),
                           (('shell', 'getconf', 'PAGE_SIZE'), '16384')]:
        if adb(*args).stdout.strip() != expected:
            raise RuntimeError('native live emulator must be booted API36 with 16KB pages')
    env = os.environ.copy()
    if not env.get('JAVA_HOME'):
        env['JAVA_HOME'] = subprocess.check_output(
            ['bash', 'tools/build-scripts/resolve-java-home.sh'], text=True).strip()
    with log_path.open('w') as log:
        # Reuse the four-ABI/JNI/checksum/alignment build; a Gradle-only
        # rebuild could otherwise execute a stale Rust shared library.
        subprocess.run(['bash', 'tools/build-scripts/build-android.sh', 'debug'],
                       env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=timeout)
        subprocess.run(['android/gradlew', '-p', 'android',
                        ':app:assembleDebugAndroidTest', '--console=plain'],
                       env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=timeout)
    adb('install', '-r', 'android/app/build/outputs/apk/debug/app-debug.apk')
    app_shell('test ! -e files/native-pairing-fixture.json && test ! -e files/native-pairing-result.json && test ! -e files/native-pairing-failure.png')
    app_shell('mkdir -p files')

try:
    if kind == 'native':
        prepare_native()
        existing_devices = {row['device_id'] for row in api('/api/device/desktop/devices')['devices']}
    fixture = api('/api/workspaces', 'POST', {'name': fixture_name})
    fixture_id = fixture['id']
    if fixture_id in existing or fixture.get('name') != fixture_name:
        fixture_id = None
        raise RuntimeError('workspace creation did not return an owned private fixture')
    result['ownedWorkspace'] = {'id': fixture_id, 'name': fixture_name}
    (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    ready = api('/api/workspaces')
    if (ready.get('current') != before['current'] or not any(
            row['id'] == fixture_id and row['name'] == fixture_name for row in ready['workspaces'])):
        raise RuntimeError('second-workspace prerequisite was not established')
    token = api('/api/device/desktop/mint-pair-token', 'POST',
                {'workspaceId': fixture_id if kind == 'native' else workspace})
    result['pairTokenExpiresAt'] = token.get('expiresAt')
    env = os.environ.copy()
    env.update(PAPERCUP_LIVE_BASE=base, PAPERCUP_LIVE_PAIR_TOKEN=token['qrPayload']['pairToken'],
               PAPERCUP_LIVE_SECOND_WORKSPACE=fixture_id)
    env.pop('PAPERCUP_LIVE_CONVERSE', None)
    if kind == 'native':
        port = url.port
        if not port:
            raise RuntimeError('native live checks require an explicit loopback port')
        mapping = f'tcp:{port}'
        if any(mapping in line.split() for line in adb('reverse', '--list').stdout.splitlines()):
            raise RuntimeError('refusing to replace an existing emulator reverse mapping')
        adb('reverse', mapping, mapping)
        reverse_created = True
        payload = dict(token['qrPayload'], server=f'http://127.0.0.1:{port}', workspaceId=fixture_id)
        app_shell('umask 077; set -C; cat > files/native-pairing-fixture.json',
            input=json.dumps({'schemaVersion': 1, 'runId': attempt,
                             'workspaceId': fixture_id, 'pairPayload': payload}))
        native_payload_created = True
        shutil.rmtree(connected, ignore_errors=True)
        command = ['android/gradlew', '-p', 'android', ':app:connectedDebugAndroidTest',
                   '--rerun', '--console=plain',
                   '-Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true',
                   '-Pandroid.testInstrumentationRunnerArguments.class=com.papercuspai.operator.mobile.PapercupAppSmokeTest#launcherActivityStarts',
                   '-Pandroid.testInstrumentationRunnerArguments.nativePairingFixture=true']
        env['ANDROID_SERIAL'] = native_device
        if not env.get('JAVA_HOME'):
            env['JAVA_HOME'] = subprocess.check_output(
                ['bash', 'tools/build-scripts/resolve-java-home.sh'], text=True).strip()
        result.update(command=command, scope='Owned local debug native pairing/JNI/navigation with external browser intent fixture; no signed-candidate, mesh, phone or Play acceptance',
                      sourceFingerprints={path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
                          for path in ['tools/run-android-checks.sh',
                            'tools/build-scripts/build-android.sh',
                            'android/app/build.gradle.kts',
                            'android/app/src/main/kotlin/com/papercuspai/operator/mobile/SettingsScreen.kt',
                            'android/app/src/main/kotlin/com/papercuspai/operator/mobile/DiagnosticsScreen.kt',
                            'android/app/src/androidTest/kotlin/com/papercuspai/operator/mobile/PapercupAppSmokeTest.kt']})
    with log_path.open('a' if kind == 'native' else 'w') as log:
        native_execution_started = kind == 'native'
        try:
            completed = subprocess.run(command, env=env, stdout=log,
                                       stderr=subprocess.STDOUT, timeout=timeout)
            result['exitCode'] = completed.returncode
        except subprocess.TimeoutExpired:
            result['exitCode'] = 124
            errors.append('canonical live smoke exceeded its execution deadline')
    text = log_path.read_text()
    if kind == 'native' and result['exitCode'] == 0:
        reports = list(connected.rglob('TEST-*.xml'))
        cases = [case for file in reports for case in ET.parse(file).getroot().iter('testcase')]
        if (len(cases) != 1 or cases[0].get('name') != 'launcherActivityStarts'
                or any(case.find(tag) is not None for case in cases for tag in ('failure', 'error', 'skipped'))
                or any(int(suite.get(tag, '0')) for file in reports
                       for suite in ET.parse(file).getroot().iter('testsuite')
                       for tag in ('failures', 'errors', 'skipped'))):
            raise RuntimeError('native live test must execute exactly once without failures or skips')
        proof = json.loads(app_shell('cat files/native-pairing-result.json').stdout)
        if (proof.get('runId') != attempt or proof.get('workspaceId') != fixture_id
                or not all(proof.get(k) is True for k in
                    ('journeyCompleted', 'authenticatedRequestPassed', 'returnedToPairedShell',
                     'activityRecreated', 'valueRowLabelsPassed', 'enrollmentBrowserStubbed',
                     'navigationPassed', 'credentialsCleared'))):
            raise RuntimeError('native live journey proof is missing, mismatched or incomplete')
        registered = api('/api/device/desktop/devices')['devices']
        if (proof.get('deviceId') in existing_devices or not any(
                row['device_id'] == proof.get('deviceId') and row.get('workspace_id') == fixture_id
                for row in registered)):
            raise RuntimeError('native proof must name a newly paired device in the owned workspace')
        result['nativeJourney'] = proof
    if kind == 'rust' and result['exitCode'] == 0 and not re.search(
            r'test result: ok\. 1 passed; 0 failed; 0 ignored;', text):
        result['exitCode'] = 1
        errors.append('canonical live test did not execute exactly once without failures or skips')
except Exception as error:
    errors.append(str(error))
    result['exitCode'] = result['exitCode'] or 1
finally:
    if native_execution_started:
        try:
            if result['exitCode'] != 0:
                # A failing JUnit verdict is never admitted as a journey,
                # but its bounded private witness identifies the failed stage.
                observed = app_shell('cat files/native-pairing-result.json', check=False)
                if observed.returncode == 0:
                    result['nativeObservedProof'] = json.loads(observed.stdout)
                else:
                    result['nativeProofUnavailable'] = True
                if app_shell('test -f files/native-pairing-failure.png', check=False).returncode == 0:
                    screenshot = out / 'native-pairing-failure.png'
                    with screenshot.open('wb') as image:
                        subprocess.run(['adb', '-s', native_device, 'exec-out', 'run-as', app,
                                        'cat', 'files/native-pairing-failure.png'], stdout=image,
                                       stderr=subprocess.PIPE, check=True, timeout=30)
                    screenshot.chmod(0o600)
                    result['failureScreenshot'] = str(screenshot)
            # Failed journeys need the same immutable APK/XML evidence as
            # passing ones; the next connected run replaces Gradle reports.
            if connected.is_dir():
                shutil.copytree(connected, out / 'native-results')
            result['artifacts'] = []
            for source in [Path('android/app/build/outputs/apk/debug/app-debug.apk'),
                           Path('android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk')]:
                target = out / source.name
                shutil.copy2(source, target)
                result['artifacts'].append({'path': str(target), 'sha256': hashlib.sha256(target.read_bytes()).hexdigest()})
        except Exception as error:
            errors.append('retain native evidence: ' + str(error))
            result['exitCode'] = result['exitCode'] or 1
    # A local cleanup failure must not strand the remote fixture as well.
    local_cleanup = []
    local_cleanup_ok = True
    if kind == 'native' and native_payload_created:
        local_cleanup.extend([
            ('stop native callbacks', lambda: adb('shell', 'am', 'force-stop', app)),
            ('remove owned private inputs', lambda: app_shell('rm -f files/native-pairing-fixture.json files/native-pairing-result.json files/native-pairing-failure.png')),
        ])
    if reverse_created:
        local_cleanup.append(('remove owned reverse mapping', lambda: adb('reverse', '--remove', f'tcp:{url.port}')))
    for label, action in local_cleanup:
        try:
            action()
        except Exception as error:
            local_cleanup_ok = False
            errors.append(label + ': ' + str(error))
            result['exitCode'] = result['exitCode'] or 1
    try:
        # A timeout can kill Cargo before its Rust panic cleanup. Only revoke
        # the fresh identity printed by this canonical, privately minted run.
        text = log_path.read_text() if log_path.exists() else ''
        if kind == 'native' and fixture_id:
            # Burn an unused one-use token before deleting its workspace.
            # A completed native redemption instead returns the expected401.
            if token is not None:
                try:
                    burned = api('/api/device/pair', 'POST', {'pairToken': token['qrPayload']['pairToken']})
                    if burned.get('deviceId') and burned['deviceId'] not in existing_devices:
                        result['ownedDeviceIds'].append(burned['deviceId'])
                except HTTPError as error:
                    if error.code != 401 or json.load(error).get('error') != 'invalid_or_expired_token':
                        raise
            # The random new workspace had no devices before this attempt.
            # Discover failed/late pairings even when JUnit did not emit proof.
            for row in api('/api/device/desktop/devices')['devices']:
                if row.get('workspace_id') == fixture_id:
                    if row['device_id'] in existing_devices:
                        raise RuntimeError('refusing to revoke a pre-existing device identity')
                    if row['device_id'] not in result['ownedDeviceIds']:
                        result['ownedDeviceIds'].append(row['device_id'])
                    api('/api/device/desktop/devices/' + row['device_id'], 'DELETE')
            if any(row.get('workspace_id') == fixture_id
                   for row in api('/api/device/desktop/devices')['devices']):
                raise RuntimeError('native fixture pairing remained after revocation')
        paired = re.search(r'^paired: device=([0-9a-f-]{36}) workspace=', text, re.MULTILINE) if kind == 'rust' else None
        if paired:
            device = paired.group(1)
            result['ownedDeviceIds'].append(device)
            api('/api/device/desktop/devices/' + device, 'DELETE')
            if any(row['device_id'] == device for row in api('/api/device/desktop/devices')['devices']):
                raise RuntimeError('private live pairing remained after revocation')
        if fixture_id:
            registered = api('/api/workspaces')
            row = next((row for row in registered['workspaces'] if row['id'] == fixture_id), None)
            if row and row['name'] != fixture_name:
                raise RuntimeError('private workspace changed identity; refusing removal')
            if row:
                api('/api/workspaces/' + urllib.parse.quote(fixture_id, safe=''), 'DELETE')
        after = api('/api/workspaces')
        if (after.get('current') != before['current'] or
                fixture_id and any(row['id'] == fixture_id for row in after['workspaces'])):
            raise RuntimeError('workspace cleanup or current-selection preservation failed')
        result['cleanupVerified'] = local_cleanup_ok
    except Exception as error:
        errors.append('cleanup: ' + str(error))
        result['exitCode'] = result['exitCode'] or 1
result.update(finishedAt=now(), errors=errors)
(out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
raise SystemExit(result['exitCode'])
PY
    exit
fi
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
    echo 'usage: run-android-checks.sh [host|connected|full|live [EVIDENCE_DIR] [rust|native]|prepare-ci|verify-emulator|verify-avd-space DISK_SIZE|verify-results ROOT host|connected]' >&2
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

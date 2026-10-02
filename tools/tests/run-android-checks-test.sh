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

# Exercise the live runner through actual HTTP and subprocess boundaries.
# The fake Cargo process is deliberately separate from the fixture server:
# skipped/empty exits, failed tests and interruption must all clean only the
# resources created for this attempt, without changing desktop selection.
python3 - "$runner" "$TMP_ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import shutil
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

runner, root = sys.argv[1], Path(sys.argv[2])
device = '12345678-1234-1234-1234-123456789abc'
original_device = '87654321-4321-4321-4321-cba987654321'

cases = ['pass', 'test-fail', 'empty', 'skipped', 'timeout', 'preflight-fail', 'cleanup-fail',
         'setup-unavailable', 'setup-no-selection',
         'native-pass', 'native-empty', 'native-no-scope-test', 'native-duplicate-journey',
         'native-wrong-scope-test', 'native-skipped-scope-test',
         'native-no-proof', 'native-no-label-proof', 'native-no-browser-boundary',
         'native-no-inbox-scope', 'native-no-inbox-rendering', 'native-no-inbox-unauthorized', 'native-no-inbox-recovery',
         'native-no-pairing-trace', 'native-no-progress',
         'native-timeout', 'native-test-fail', 'native-uninstalled',
         'native-preflight-fail', 'native-local-cleanup-fail', 'native-cleanup-fail',
         'native-unused-token', 'native-wrong-device', 'native-existing-files', 'native-missing-serial']
for case in cases:
    native_mode = case.startswith('native-')
    state = {'workspaces': [{'id': 'original', 'name': 'Original'}], 'current': 'original',
             'devices': [{'device_id': original_device}], 'minted': False, 'removed': [], 'hidden': False}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, body, status=200):
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(body).encode())

        def do_GET(self):
            if self.path == '/api/workspaces':
                if case == 'setup-unavailable':
                    self.reply({'error': 'fixture-unavailable'}, 503)
                    return
                rows = state['workspaces']
                if case == 'preflight-fail' and len(rows) == 2 and not state['hidden']:
                    rows = rows[:1]
                    state['hidden'] = True
                self.reply({'workspaces': rows, 'current': None if case == 'setup-no-selection' else state['current']})
            elif self.path == '/api/device/desktop/devices':
                self.reply({'devices': state['devices']})
            else:
                self.reply({'error': 'unexpected read'}, 404)

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            if self.path == '/api/workspaces':
                row = {'id': body['name'], 'name': body['name']}
                state['workspaces'].append(row)
                self.reply(row)
            elif self.path == '/api/device/desktop/mint-pair-token':
                assert len(state['workspaces']) == 2, 'mint before scope fixture exists'
                assert body['workspaceId'] == (state['workspaces'][-1]['id'] if native_mode else 'original')
                state['minted'] = True
                if case != 'native-unused-token':
                    state['devices'].append(dict(device_id=device, workspace_id=body['workspaceId'])
                                            if native_mode else {'device_id': device})
                self.reply({'qrPayload': {'pairToken': 'private-test-token'}})
            elif self.path == '/api/device/pair' and native_mode:
                assert body == {'pairToken': 'private-test-token'}
                if case == 'native-unused-token':
                    state['devices'].append({'device_id': device, 'workspace_id': state['workspaces'][-1]['id']})
                    self.reply({'deviceId': device, 'deviceToken': 'private-test-only'})
                else:
                    self.reply({'error': 'invalid_or_expired_token'}, 401)
            else:
                self.reply({'error': 'unexpected write'}, 404)

        def do_DELETE(self):
            if self.path.startswith('/api/device/desktop/devices/'):
                owned = self.path.rsplit('/', 1)[1]
                assert owned == device, 'attempt to revoke pre-existing device'
                state['devices'] = [row for row in state['devices'] if row['device_id'] != owned]
                self.reply({'ok': True})
            elif self.path.startswith('/api/workspaces/'):
                owned = self.path.rsplit('/', 1)[1]
                assert owned != 'original', 'attempt to remove pre-existing workspace'
                if case in ('cleanup-fail', 'native-cleanup-fail'):
                    self.reply({'error': 'cleanup rejected'}, 503)
                else:
                    state['removed'].append(owned)
                    state['workspaces'] = [row for row in state['workspaces'] if row['id'] != owned]
                    self.reply({'ok': True})
            else:
                self.reply({'error': 'unexpected deletion'}, 404)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    bin_dir = root / ('live-bin-' + case)
    bin_dir.mkdir()
    cargo = bin_dir / 'cargo'
    cargo.write_text('''#!/usr/bin/env python3
import os, sys, time
assert sys.argv[1:] == ['test', '-p', 'papercup-core', '--test', 'live_smoke', 'live_p0_contract_smoke', '--', '--ignored', '--nocapture']
assert os.environ['PAPERCUP_LIVE_PAIR_TOKEN'] == 'private-test-token'
assert os.environ['PAPERCUP_LIVE_SECOND_WORKSPACE'].startswith('android-live-scope-')
assert 'PAPERCUP_LIVE_CONVERSE' not in os.environ
print('paired: device=12345678-1234-1234-1234-123456789abc workspace=original', flush=True)
case = os.environ['TEST_LIVE_CASE']
if case == 'timeout': time.sleep(5)
if case == 'empty': sys.exit(0)
if case == 'skipped':
    print('test result: ok. 0 passed; 0 failed; 1 ignored;')
else:
    print('test result: ok. 1 passed; 0 failed; 0 ignored;')
sys.exit(101 if case == 'test-fail' else 0)
''')
    cargo.chmod(0o755)
    env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
               PAPERCUP_LIVE_BASE=f'http://127.0.0.1:{server.server_port}',
               PAPERCUP_LIVE_CONVERSE='1', PAPERCUP_LIVE_TIMEOUT_SEC='1', TEST_LIVE_CASE=case)
    selected_runner = runner
    if native_mode:
        # Run the real maintained script in a private fixture tree. Fake ADB
        # and Gradle are separate processes; no production build reports,
        # connected devices, credentials or working-tree files are touched.
        native_root = root / ('native-root-' + case)
        for relative in ['tools/run-android-checks.sh', 'crates/papercup-core/tests/live_smoke.rs',
                         'android/app/build.gradle.kts',
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/SettingsScreen.kt',
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/DiagnosticsScreen.kt',
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/MainActivity.kt',
                         'android/app/src/main/AndroidManifest.xml',
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/PapercupApplication.kt',
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/InboxScreen.kt',
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/CompanionFeed.kt',
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/Credentials.kt',
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/HumanError.kt',
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/PairScreen.kt',
                         'android/app/src/androidTest/kotlin/com/papercuspai/operator/mobile/PapercupAppSmokeTest.kt',
                         'android/app/src/androidTest/kotlin/com/papercuspai/operator/mobile/UniffiCallbackTest.kt']:
            target = native_root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(Path(runner).parent.parent / relative, target)
        selected_runner = str(native_root / 'tools/run-android-checks.sh')
        builder = native_root / 'tools/build-scripts/build-android.sh'
        builder.parent.mkdir(parents=True, exist_ok=True)
        builder.write_text('#!/bin/sh\nset -eu\n[ "$1" = debug ]\ntouch native-build-executed\n')
        git = bin_dir / 'git'
        git.write_text('#!/bin/sh\nif [ "$1" = rev-parse ]; then printf "%040d\\n" 1; fi\n')
        git.chmod(0o755)
        adb = bin_dir / 'adb'
        adb.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
case = os.environ['TEST_LIVE_CASE']
if args == ['devices']:
    print('List of devices attached\\nemulator-5556 device')
    sys.exit(0)
assert args[:2] == ['-s', 'emulator-5556']
args = args[2:]
private = Path('private-fixture.json')
if args == ['shell', 'getprop', 'sys.boot_completed']: print('1')
elif args == ['shell', 'getprop', 'ro.build.version.sdk']: print('36')
elif args == ['shell', 'getconf', 'PAGE_SIZE']: print('4096' if case == 'native-preflight-fail' else '16384')
elif args[:2] == ['logcat', '-d']:
    if case != 'native-no-pairing-trace':
        for stage in ['client-start', 'client-ready', 'request-start', 'response-received', 'credentials-saved']:
            print('1.0 I PapercupPairing: stage=' + stage)
elif args[:2] == ['reverse', '--list']: pass
elif args[:2] == ['reverse', '--remove']:
    if case == 'native-local-cleanup-fail': sys.exit(1)
elif args and args[0] in ['reverse', 'install']: pass
elif args == ['shell', 'am', 'force-stop', 'com.papercuspai.operator.mobile']: pass
elif args[0] == 'shell':
    command = args[1]
    if 'run-as ' in command and Path('app-uninstalled').exists(): sys.exit(1)
    if 'cat > files/native-pairing-fixture.json' in command:
        fixture = json.load(sys.stdin)
        assert fixture['pairPayload']['pairToken'] == 'private-test-token'
        assert fixture['pairPayload']['server'].startswith('http://127.0.0.1:')
        assert fixture['workspaceId'].startswith('android-live-scope-')
        private.write_text(json.dumps(fixture))
    elif 'cat files/native-pairing-result.json' in command:
        fixture = json.loads(private.read_text())
        proof = {'runId': fixture['runId'], 'workspaceId': fixture['workspaceId'],
                 'deviceId': '12345678-1234-1234-1234-123456789abc',
                 'journeyCompleted': True, 'currentStage': 'completed', 'authenticatedRequestPassed': True,
                 'returnedToPairedShell': True, 'activityRecreated': True,
                 'valueRowLabelsPassed': True, 'enrollmentBrowserStubbed': True,
                 'inboxScopedReadPassed': True, 'inboxRenderingPassed': True,
                 'inboxUnauthorizedPassed': True, 'inboxRecoveryPassed': True,
                 'navigationPassed': True, 'credentialsCleared': True}
        if case == 'native-wrong-device': proof['deviceId'] = '87654321-4321-4321-4321-cba987654321'
        if case == 'native-no-label-proof': proof.pop('valueRowLabelsPassed')
        if case == 'native-no-browser-boundary': proof.pop('enrollmentBrowserStubbed')
        if case == 'native-no-progress': proof.pop('currentStage')
        if case == 'native-timeout':
            proof.update(journeyCompleted=False, currentStage='authenticated-jni-request')
        for suffix, flag in [('scope', 'inboxScopedReadPassed'), ('rendering', 'inboxRenderingPassed'),
                             ('unauthorized', 'inboxUnauthorizedPassed'), ('recovery', 'inboxRecoveryPassed')]:
            if case == 'native-no-inbox-' + suffix: proof.pop(flag)
        if case == 'native-test-fail':
            proof.update(journeyCompleted=False, failedStage='persisted-credentials', failureClass='FixtureFailure')
        print(json.dumps({} if case == 'native-no-proof' else proof))
    elif 'test -f files/native-pairing-failure.png' in command: sys.exit(1)
    elif 'rm -f files/native-pairing-fixture.json' in command: private.unlink()
    else:
        assert 'test ! -e' in command or 'mkdir -p files' in command, command
        if 'test ! -e' in command and case == 'native-existing-files': sys.exit(1)
else: raise AssertionError(args)
''')
        adb.chmod(0o755)
        gradle = native_root / 'android/gradlew'
        gradle.write_text('''#!/usr/bin/env python3
import os, sys, time
from pathlib import Path
case = os.environ['TEST_LIVE_CASE']
if ':app:assembleDebugAndroidTest' in sys.argv:
    assert Path('native-build-executed').exists(), 'native gate reused an unverified JNI library'
    for name in ['debug/app-debug.apk', 'androidTest/debug/app-debug-androidTest.apk']:
        p = Path('android/app/build/outputs/apk') / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b'fixture-apk')
else:
    assert ':app:connectedDebugAndroidTest' in sys.argv
    assert '--rerun' in sys.argv and '--rerun-tasks' not in sys.argv, 'live gate rebuilt after minting its one-use token'
    assert '-Pandroid.testInstrumentationRunnerArguments.nativePairingFixture=true' in sys.argv
    assert any('PapercupAppSmokeTest#launcherActivityStarts' in arg for arg in sys.argv)
    assert any('PapercupAppSmokeTest#privateInboxScopeAcceptsOnlyDocumentedGlobalControls' in arg for arg in sys.argv)
    assert all('private-test-token' not in arg for arg in sys.argv)
    if case == 'native-timeout': time.sleep(5)
    p = Path('android/app/build/outputs/androidTest-results/connected/debug/TEST-native.xml')
    p.parent.mkdir(parents=True, exist_ok=True)
    journey = '<testcase name="launcherActivityStarts"/>'
    scope = '<testcase name="privateInboxScopeAcceptsOnlyDocumentedGlobalControls"/>'
    if case == 'native-no-scope-test': scope = ''
    if case == 'native-duplicate-journey': scope = journey
    if case == 'native-wrong-scope-test': scope = '<testcase name="unrelatedTest"/>'
    if case == 'native-skipped-scope-test':
        scope = '<testcase name="privateInboxScopeAcceptsOnlyDocumentedGlobalControls"><skipped/></testcase>'
    p.write_text('<testsuite tests="0"/>' if case == 'native-empty' else
                 '<testsuite tests="2" failures="1"><testcase name="launcherActivityStarts"><failure>lifecycle failure</failure></testcase>' + scope + '</testsuite>' if case == 'native-test-fail' else
                 '<testsuite tests="2">' + journey + scope + '</testsuite>')
    # AGP uninstalls both packages by default, deleting app-private proof.
    # Model that side effect so a missing retention option cannot pass here.
    if case == 'native-uninstalled' or '-Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true' not in sys.argv:
        Path('app-uninstalled').touch()
        Path('private-fixture.json').unlink()
    if case in ('native-unused-token', 'native-test-fail'): sys.exit(1)
''')
        gradle.chmod(0o755)
        env.update(JAVA_HOME=str(native_root / 'jdk'), ANDROID_SERIAL='emulator-5556')
        if case == 'native-missing-serial':
            env.pop('ANDROID_SERIAL')
        if case == 'native-existing-files':
            (native_root / 'private-fixture.json').write_text('{"owner":"pre-existing"}')
    evidence = root / ('live-evidence-' + case)
    try:
        run = subprocess.run(['bash', selected_runner, 'live', str(evidence), 'native' if native_mode else 'rust'], env=env,
                             capture_output=True, text=True, timeout=15)
        result = json.loads((evidence / 'result.json').read_text())
        assert (run.returncode == 0) == (case in ('pass', 'native-pass')), (case, run.stdout, run.stderr, result)
        assert state['current'] == 'original'
        assert result['checkKind'] == ('native' if native_mode else 'rust')
        assert len(result['runId']) == 32
        if case not in ('setup-unavailable', 'setup-no-selection', 'native-preflight-fail', 'native-existing-files', 'native-missing-serial'):
            assert result['ownedWorkspace']['name'].startswith('android-live-scope-')
        else:
            assert result['ownedWorkspace'] is None
        assert state['devices'] == [{'device_id': original_device}], state
        if case in ('cleanup-fail', 'native-cleanup-fail'):
            assert not result['cleanupVerified'] and len(state['workspaces']) == 2
        else:
            assert result['cleanupVerified'] == (case not in ('native-local-cleanup-fail', 'native-uninstalled')), (case, result)
            assert state['workspaces'] == [{'id': 'original', 'name': 'Original'}], (case, result, state)
        if case in ('setup-unavailable', 'setup-no-selection', 'preflight-fail', 'native-preflight-fail', 'native-existing-files', 'native-missing-serial'):
            assert not state['minted'], 'failed fixture preflight still minted credentials'
        if case in ('setup-unavailable', 'setup-no-selection'):
            assert result['setupFailed'] and not result['executionStarted']
        if native_mode:
            if state['minted']:
                assert result['nativePairTokenDisposition'] == ('redeemed-by-cleanup' if case == 'native-unused-token' else 'redeemed-before-cleanup'), (case, result)
            if case == 'native-existing-files':
                assert (native_root / 'private-fixture.json').read_text() == '{"owner":"pre-existing"}'
            else:
                assert not (native_root / 'private-fixture.json').exists(), 'private pairing input remained'
        if case == 'native-pass':
            assert result['nativeJourney']['journeyCompleted'] is True
            assert len(result['artifacts']) == 2
            assert result['ownedDeviceIds'] == [device]
        if case == 'native-test-fail':
            xml = evidence / 'native-results/TEST-native.xml'
            assert '<failure>lifecycle failure</failure>' in xml.read_text(), 'failed native evidence was discarded'
            assert len(result['artifacts']) == 2, 'failed run lost its exact APKs'
            assert result['nativeObservedProof']['failedStage'] == 'persisted-credentials', 'failure-stage witness was discarded'
        if case == 'native-timeout':
            assert result['exitCode'] == 124 and 'nativeJourney' not in result
            assert result['nativeObservedProof']['currentStage'] == 'authenticated-jni-request'
            assert not result['nativeObservedProof']['journeyCompleted']
            assert len(result['artifacts']) == 2, 'interrupted native run lost its exact APKs'
        if case == 'native-uninstalled':
            assert not result['cleanupVerified'] and result['ownedDeviceIds'] == [device]
            assert len(result['artifacts']) == 2, 'AGP teardown lost the immutable artifacts'
        assert 'private-test-token' not in run.stdout + run.stderr + (evidence / 'result.json').read_text()
    finally:
        server.shutdown()
        server.server_close()
        thread.join()

remote = subprocess.run(['bash', runner, 'live', str(root / 'remote-refused')],
    env=dict(os.environ, PAPERCUP_LIVE_BASE='https://public.example'), capture_output=True, text=True)
assert remote.returncode != 0 and not (root / 'remote-refused').exists()

# A real connection refusal must retain the same structured setup failure.
# This runs the canonical runner, and intentionally starts no fake Cargo/ADB.
import socket
with socket.socket() as reserved:
    reserved.bind(('127.0.0.1', 0))
    offline_port = reserved.getsockname()[1]
offline = root / 'connection-refused'
run = subprocess.run(['bash', runner, 'live', str(offline), 'native'],
    env=dict(os.environ, PAPERCUP_LIVE_BASE=f'http://127.0.0.1:{offline_port}'),
    capture_output=True, text=True, timeout=15)
failure = json.loads((offline / 'result.json').read_text())
assert run.returncode != 0 and failure['exitCode'] != 0
assert failure['setupFailed'] and failure['setupFailureClass'] == 'URLError'
assert not failure['executionStarted'] and failure['ownedWorkspace'] is None
assert failure['ownedDeviceIds'] == [] and failure['cleanupVerified']
assert failure['errors'] and failure['finishedAt']
print(f'Android live fixture guards: {len(cases) + 2} passed; Rust/native ownership, executed proof and independent cleanup verified')
PY
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
for port in 5554 5584; do
    ANDROID_HOME="$TMP_ROOT/sdk" PATH="$TMP_ROOT/bin:$PATH" bash "$runner" verify-emulator "$TMP_ROOT/valid-port-$port" "$port"
done
for port in 5553 5555 5586 5596 invalid; do
    if ANDROID_HOME="$TMP_ROOT/sdk" PATH="$TMP_ROOT/bin:$PATH" bash "$runner" verify-emulator "$TMP_ROOT/invalid-port-$port" "$port" > "$TMP_ROOT/output" 2>&1; then
        echo "FAIL: unsupported emulator discovery port accepted: $port" >&2
        exit 1
    fi
done
mkdir -p "$TMP_ROOT/boot-bin"
cat > "$TMP_ROOT/boot-bin/adb" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == '-s emulator-5584 shell getprop sys.boot_completed' ]]; then
    if [[ "${TEST_BOOT_READY:-0}" == 1 ]]; then printf '1\r\n'; else echo 'error: device not found' >&2; exit 1; fi
elif [[ "$*" == 'devices -l' ]]; then
    printf 'List of devices attached\n'
else
    echo "unexpected boot fixture command: $*" >&2; exit 1
fi
SH
chmod +x "$TMP_ROOT/boot-bin/adb"
TEST_BOOT_READY=1 PATH="$TMP_ROOT/boot-bin:$PATH" bash "$runner" verify-emulator-boot emulator-5584 "$TMP_ROOT/boot-pass" 1
if PATH="$TMP_ROOT/boot-bin:$PATH" bash "$runner" verify-emulator-boot emulator-5584 "$TMP_ROOT/boot-fail" 1 > "$TMP_ROOT/output" 2>&1; then
    echo 'FAIL: missing ADB transport accepted as a booted emulator' >&2; exit 1
fi
python3 - "$TMP_ROOT" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
assert json.loads((root / 'boot-pass/emulator-boot.json').read_text())['bootCompleted'] is True
bad = json.loads((root / 'boot-fail/emulator-boot.json').read_text())
assert bad['bootCompleted'] is False and 'device not found' in bad['adbError']
assert (root / 'boot-fail/boot-transports.txt').is_file()
PY
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

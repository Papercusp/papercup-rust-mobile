#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
suite="${1:-all}"
[[ "$suite" == all || "$suite" == boot || "$suite" == live || "$suite" == generation || "$suite" == toolchain || "$suite" == cloud ]] || { echo 'Expected all, boot, live, generation, toolchain or cloud suite' >&2; exit 2; }
[[ "$suite" == live || -z "${2:-}" ]] || { echo 'Case selection requires the live suite' >&2; exit 2; }
mkdir -p "$ROOT/android/app/build/ci-evidence"
TMP_ROOT="$(mktemp -d "$ROOT/android/app/build/ci-evidence/runner-fixtures.XXXXXX")"
cleanup() {
    status=$?
    if (( status == 0 )); then
        rm -rf "$TMP_ROOT"
    else
        printf 'Android runner fixture failure (exit %s); retained evidence: %s\n' "$status" "$TMP_ROOT" >&2
    fi
}
trap cleanup EXIT
runner="$ROOT/tools/run-android-checks.sh"
if [[ "$suite" == all || "$suite" == cloud ]]; then
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import base64, hashlib, importlib.util, json, os, subprocess, sys
from pathlib import Path
from unittest.mock import patch
root, temp = map(Path, sys.argv[1:])
# Exercise dispatch before its usual host/connected tail. No SDK environment
# is supplied; the helper must receive the shared default before any build.
dispatch = temp / 'cloud-dispatch'; (dispatch / 'tools').mkdir(parents=True)
(dispatch / 'tools/run-android-checks.sh').write_text((root / 'tools/run-android-checks.sh').read_text())
(dispatch / 'tools/cloud-native-check.py').write_text(
    'import os; print(os.environ["ANDROID_HOME"]); print(os.environ["ANDROID_SDK_ROOT"])')
env = dict(os.environ, HOME=str(temp / 'owned-home'))
env.pop('ANDROID_HOME', None); env.pop('ANDROID_SDK_ROOT', None)
# This dispatch control owns SDK ordering, not a real rustup invocation in a
# deliberately empty HOME. Toolchain failure semantics have their own suite.
bin_dir = dispatch / 'bin'; bin_dir.mkdir()
for tool in ('cargo', 'rustc'):
    command = bin_dir / tool; command.write_text('#!/bin/sh\nexit 0\n'); command.chmod(0o755)
env['PATH'] = str(bin_dir) + ':' + env['PATH']
run = subprocess.run(['bash', str(dispatch / 'tools/run-android-checks.sh'), 'cloud-native', 'out', 'qr'],
                     env=env, text=True, capture_output=True, check=True, timeout=15)
assert run.stdout.splitlines() == [str(temp / 'owned-home/Android/Sdk')] * 2
spec = importlib.util.spec_from_file_location('cloud_runner', root / 'tools/cloud-native-check.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
log = ('I/PapercupPairing(12): stage=request-start\n'
       'I/PapercupPairing(12): stage=pair-failed class=Decode\n'
       'I/Other(12): secret=private-token\n'
       'I/PapercupPairing(12): stage=pair-failed class=Decode private-token\n')
assert module.pairing_stages(log) == [{'stage': 'request-start'},
                                    {'stage': 'pair-failed', 'failureClass': 'Decode'}]
assert 'private-token' not in json.dumps(module.pairing_stages(log))
print('Cloud failure diagnostics: safe native stages/classes retained; raw private text refused PASS')
# Fresh Android installs have no files/ directory. Execute the actual shell
# preparation in an empty sandbox, and refuse replacement of prior input.
guest = temp / 'fresh-cloud-guest'; guest.mkdir()
def guest_adb(*args, **kwargs):
    assert args[0] == 'shell'
    if len(args) == 2:
        command = args[1].removeprefix('run-as owned.app ')
        return subprocess.run(command, shell=True, cwd=guest, text=True, capture_output=True, **kwargs)
    assert args[1:3] == ('run-as', 'owned.app')
    return subprocess.run(args[3:], cwd=guest, text=True, capture_output=True, **kwargs)
module.inject_pairing_input(guest_adb, 'owned.app', 'private-owned-input')
input_file = guest / 'files/cloud-pairing-input.json'
assert input_file.read_text() == 'private-owned-input'
assert input_file.stat().st_mode & 0o777 == 0o600
try:
    module.inject_pairing_input(guest_adb, 'owned.app', 'replacement')
except subprocess.CalledProcessError:
    pass
else:
    raise AssertionError('Cloud input replacement was accepted')
assert input_file.read_text() == 'private-owned-input'
print('Cloud input preparation: fresh directory/private input and preserved prior input PASS')
base = 'https://cloud.example.com/api/workspaces/ws-owned'
qr = {'server': base, 'workspaceId': 'workspace-owned', 'pairToken': 'one-use-private',
      'noiseKey': base64.b64encode(bytes(range(32))).decode()}
path = temp / 'qr.json'; path.write_text(json.dumps(qr)); path.chmod(0o600)
assert module.validate_input(path, 'emulator-5584', base) == qr
def refused(fn):
    try: fn()
    except ValueError: return
    raise AssertionError('Unsafe cloud candidate accepted')
for server in ('http://cloud.example.com/api/workspaces/ws-owned',
               'https://127.0.0.1/api/workspaces/ws-owned',
               'https://10.1.2.3/api/workspaces/ws-owned',
               'https://[::1]/api/workspaces/ws-owned',
               'https://localhost/api/workspaces/ws-owned',
               'https://cloud.example.com/api/workspaces/ws-owned?token=x',
               'https://user:password@cloud.example.com/api/workspaces/ws-owned',
               'https://cloud.example.com/api/device'):
    path.write_text(json.dumps(dict(qr, server=server)))
    refused(lambda: module.validate_input(path, 'emulator-5584', server))
for changes in ({'noiseKey': ''}, {'noiseKey': 'not-base64'}, {'pairToken': ''}, {'workspaceId': ''}):
    path.write_text(json.dumps(dict(qr, **changes)))
    refused(lambda: module.validate_input(path, 'emulator-5584', base))
path.write_text(json.dumps(qr))
for serial in ('', 'physical-peer', 'emulator-5584;kill'):
    refused(lambda: module.validate_input(path, serial, base))
refused(lambda: module.validate_input(path, 'emulator-5584', base + '-another'))
path.chmod(0o644)
refused(lambda: module.validate_input(path, 'emulator-5584', base))
source, captured = temp / 'source.apk', temp / 'captured.apk'
source.write_bytes(b'current-candidate')
assert module.capture_apk(source, captured) == hashlib.sha256(b'current-candidate').hexdigest()
copy = module.shutil.copyfile
def racing_copy(src, dest):
    copy(src, dest); Path(src).write_bytes(b'advanced-candidate')
with patch.object(module.shutil, 'copyfile', racing_copy):
    refused(lambda: module.capture_apk(source, captured))
assert not captured.exists()
fields = ('encryptedRestore', 'reconnectAndScope', 'readOperations', 'navigation',
          'revoked', 'revokedTokenRejected', 'credentialsCleared')
proof = dict.fromkeys(fields, True)
proof.update(runId='owned-run', workspaceId='workspace-owned', stage='completed')
output = 'OK (1 test)\nINSTRUMENTATION_CODE: -1\n'
module.verify_proof(proof, 'owned-run', 'workspace-owned', output)
for field in fields:
    refused(lambda: module.verify_proof(dict(proof, **{field: False}), 'owned-run', 'workspace-owned', output))
for changes in ({'runId': 'old-run'}, {'workspaceId': 'peer-workspace'}, {'stage': 'pairing'}):
    refused(lambda: module.verify_proof(dict(proof, **changes), 'owned-run', 'workspace-owned', output))
for log in ('OK (0 tests)\nINSTRUMENTATION_CODE: -1', 'OK (1 test)', output + 'FAILURES!!!'):
    refused(lambda: module.verify_proof(proof, 'owned-run', 'workspace-owned', log))
print('Cloud native guards: public pinned QR/current APK accepted; 31 unsafe-input/race/incomplete-proof controls refused')
# Exercise main's actual failure/finally path, beyond the pure log parser.
# Both a native assertion and a missing instrumentation completion must leave
# scoped proof and remove our input, without retaining raw logcat secrets.
path.chmod(0o600)
for failure_mode in ('assertion', 'timeout'):
    out = temp / ('cloud-failure-' + failure_mode)
    calls = []
    saved = {'runId': 'owned-run', 'workspaceId': 'workspace-owned',
             'stage': 'failed', 'failedStage': 'pairing',
             'failureClass': 'AssertionError', 'credentialsCleared': True}
    def check_output(command, **kwargs):
        if command == ['adb', 'devices']:
            return 'List of devices attached\nemulator-5582\tdevice\nemulator-5584\tdevice\n'
        if command[:2] == ['git', 'rev-parse']: return 'fixture-source\n'
        if command[:2] == ['git', 'status']: return ''
        if command == ['bash', 'tools/build-scripts/resolve-java-home.sh']: return '/fixture/jdk\n'
        raise AssertionError(command)
    def run_command(command, **kwargs):
        calls.append(command)
        if command[0] != 'adb':
            assert command[0] in ('bash', 'android/gradlew')
            return subprocess.CompletedProcess(command, 0, '', '')
        assert command[:3] == ['adb', '-s', 'emulator-5584']
        args = command[3:]
        output = ''
        if args == ['shell', 'getprop', 'ro.build.version.sdk']: output = '36\n'
        elif args == ['shell', 'getconf', 'PAGE_SIZE']: output = '16384\n'
        elif args[:3] == ['shell', 'pm', 'path']: output = 'package:/owned/base.apk\n'
        elif args[0] == 'pull': Path(args[2]).write_bytes(b'held-candidate')
        elif args[:3] == ['shell', 'am', 'instrument']:
            if failure_mode == 'timeout':
                raise subprocess.TimeoutExpired(command, 300)
            output = 'FAILURES!!!\nINSTRUMENTATION_CODE: -1\n'
        elif args[:4] == ['shell', 'run-as', 'com.papercuspai.operator.mobile', 'cat']:
            output = json.dumps(saved)
        elif args[:2] == ['logcat', '-d']: output = log
        return subprocess.CompletedProcess(command, 0, output, '')
    def capture(source, destination):
        destination.write_bytes(b'held-candidate')
        return hashlib.sha256(b'held-candidate').hexdigest()
    cwd = os.getcwd()
    try:
        os.chdir(root)
        with patch.dict(os.environ, ANDROID_SERIAL='emulator-5584', PAPERCUP_CLOUD_BASE=base), \
             patch.object(sys, 'argv', ['cloud-native-check.py', str(out), str(path)]), \
             patch.object(module.subprocess, 'check_output', check_output), \
             patch.object(module.subprocess, 'run', run_command), \
             patch.object(module, 'capture_apk', capture):
            try: module.main()
            except (ValueError, subprocess.TimeoutExpired): pass
            else: raise AssertionError('Failed native journey was accepted')
    finally:
        os.chdir(cwd)
    result = json.loads((out / 'result.json').read_text())
    assert result['exitCode'] == 1 and result['installedApkMatches'] is True
    assert result['journey'] == saved
    assert result['pairingStages'] == module.pairing_stages(log)
    assert 'private-token' not in (out / 'result.json').read_text()
    assert ['adb', '-s', 'emulator-5584', 'shell', 'run-as',
            'com.papercuspai.operator.mobile', 'rm', '-f',
            'files/cloud-pairing-input.json'] in calls
    clear = calls.index(['adb', '-s', 'emulator-5584', 'logcat', '-c'])
    instrument = next(i for i, command in enumerate(calls) if command[3:6] == ['shell', 'am', 'instrument'])
    assert clear < instrument
print('Cloud failure persistence: assertion/timeout retain safe proof and clean only owned input PASS')
PY
fi
[[ "$suite" != cloud ]] || exit 0
if [[ "$suite" == all || "$suite" == toolchain ]]; then
python3 - "$runner" "$TMP_ROOT" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys

runner, temp = Path(sys.argv[1]), Path(sys.argv[2])
home = temp / 'toolchain-home'; (home / '.cargo/bin').mkdir(parents=True)
explicit = temp / 'explicit-cargo'; (explicit / 'bin').mkdir(parents=True)
selected = temp / 'selected-path'; selected.mkdir()
utilities = temp / 'toolchain-utilities'; utilities.mkdir()
(utilities / 'dirname').symlink_to(shutil.which('dirname'))
ledger = temp / 'toolchain-ledger'
def executable(root, name, status=0):
    path = root / name
    path.write_text('#!/bin/sh\nprintf "%s:%s:%s:%s\\n" "$0" "$1" "$CARGO_HOME" "$RUSTUP_HOME" >> "$TOOLCHAIN_LEDGER"\nexit ' + str(status) + '\n')
    path.chmod(0o755)
for root in (home / '.cargo/bin', explicit / 'bin', selected):
    for tool in ('cargo', 'rustc'):
        executable(root, tool)
base = dict(os.environ, HOME=str(home), PATH=str(utilities), TOOLCHAIN_LEDGER=str(ledger))
for key in ('CARGO_HOME', 'RUSTUP_HOME'):
    base.pop(key, None)
cases = ('home', 'explicit', 'path', 'missing', 'broken-cargo', 'broken-rustc')
for case in cases:
    ledger.unlink(missing_ok=True)
    env = dict(base)
    expected = home / '.cargo/bin'
    if case in ('explicit', 'missing'):
        env.update(CARGO_HOME=str(explicit if case == 'explicit' else temp / 'absent'),
                   RUSTUP_HOME=str(temp / 'explicit-rustup'))
        expected = explicit / 'bin'
    if case in ('path', 'broken-cargo', 'broken-rustc'):
        env['PATH'] = str(selected) + ':' + env['PATH']
        expected = selected
    if case.startswith('broken-'):
        executable(selected, case.removeprefix('broken-'), 17)
    run = subprocess.run(['/bin/bash', str(runner), 'verify-rust-toolchain'],
                         env=env, capture_output=True, text=True, timeout=10)
    if case in ('missing', 'broken-cargo', 'broken-rustc'):
        assert run.returncode == 2 and 'Rust toolchain preflight failed:' in run.stderr, (case, run)
    else:
        assert run.returncode == 0, (case, run.stderr)
        rows = ledger.read_text().splitlines()
        assert len(rows) == 2 and all(row.startswith(str(expected) + '/') for row in rows), rows
        assert all(':--version:' in row for row in rows), rows
        assert all(':' + env.get('CARGO_HOME', str(home / '.cargo')) + ':' in row for row in rows), rows
        assert all(row.endswith(':' + env.get('RUSTUP_HOME', str(home / '.rustup'))) for row in rows), rows
    for tool in ('cargo', 'rustc'):
        executable(selected, tool)
print('Android Rust toolchain preflight: six discovery and failure controls passed')
PY
fi
[[ "$suite" != toolchain ]] || exit 0
if [[ "$suite" == all || "$suite" == generation ]]; then
python3 - "$runner" "$TMP_ROOT" <<'PY'
import fcntl
import os
from pathlib import Path
import shutil
import subprocess
import sys

runner, temp = Path(sys.argv[1]), Path(sys.argv[2])
mobile = temp / 'generation-consumer'
(mobile / 'tools/tests').mkdir(parents=True)
bin_dir = mobile / 'bin'; bin_dir.mkdir()
lock = temp / 'staging-sync.lock'
fixture_runner = mobile / 'tools/run-android-checks.sh'
# Execute the maintained shell entry, substituting only its shared lock path.
fixture_runner.write_text(runner.read_text().replace('/tmp/papercup-staging-sync.lock', str(lock)))
old = temp / 'old-generation'; new = temp / 'new-generation'
for root in (old, new):
    (root / 'scripts').mkdir(parents=True)
    (root / 'apps/operator/dist-host').mkdir(parents=True)
    (root / 'scripts/with-test-pg.mjs').write_text('fixture')
    (root / 'apps/operator/dist-host/hono-host.mjs').write_text('fixture')
alias = temp / 'generation-current'
marker = temp / 'generation-fixture-started'
result = temp / 'generation-consumer-result'
probe = '''#!/usr/bin/env python3
import fcntl, os, sys
from pathlib import Path
expected = os.environ['EXPECTED_ROOT']
assert os.environ['PAPERCUSP_INTEGRATION_ROOT'] == expected
assert ('PAPERCUSP_INTEGRATION_ROOT=' + expected).encode() in Path('/proc/self/environ').read_bytes().split(b'\\0')
with open(os.environ['FIXTURE_LOCK'], 'a') as handle:
    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
command = Path(sys.argv[1]).name if len(sys.argv) > 1 else 'fixture'
if command == 'bundle-host-freshness.mjs':
    assert '--repo-root' in sys.argv and sys.argv[sys.argv.index('--repo-root') + 1] == expected
    sys.exit(int(os.environ.get('FRESHNESS_EXIT', '0')))
elif command == 'with-test-pg.mjs':
    assert str(Path(sys.argv[1]).parent.parent) == expected
    Path(os.environ['FIXTURE_RESULT']).write_text(expected)
else:
    Path(os.environ['FIXTURE_MARKER']).write_text('started')
    alias = Path(os.environ['FIXTURE_ALIAS']); alias.unlink()
    alias.symlink_to(os.environ['NEW_ROOT'])
'''
node = bin_dir / 'node'; node.write_text(probe); node.chmod(0o755)
cargo = bin_dir / 'cargo'; cargo.write_text('#!/bin/sh\nexit 0\n'); cargo.chmod(0o755)
rustc = bin_dir / 'rustc'; rustc.write_text('#!/bin/sh\nexit 0\n'); rustc.chmod(0o755)
(mobile / 'tools/tests/run-android-checks-test.sh').write_text('exec "' + str(node) + '"\n')
base = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'], JAVA_HOME='/fixture-java',
            EXPECTED_ROOT=str(old), FIXTURE_LOCK=str(lock), FIXTURE_MARKER=str(marker),
            FIXTURE_RESULT=str(result), FIXTURE_ALIAS=str(alias), NEW_ROOT=str(new))
base.pop('PAPERCUSP_INTEGRATION_ROOT', None)
for case in ('pass', 'stale', 'missing', 'unpinned', 'missing-cargo', 'broken-rustc'):
    alias.unlink(missing_ok=True); alias.symlink_to(old)
    marker.unlink(missing_ok=True); result.unlink(missing_ok=True)
    env = dict(base, FRESHNESS_EXIT='19' if case == 'stale' else '0')
    if case == 'missing-cargo':
        cargo.unlink()
        for tool in ('bash', 'dirname', 'realpath', 'flock', 'env', 'python3'):
            (bin_dir / tool).symlink_to(shutil.which(tool))
        env.update(PATH=str(bin_dir), CARGO_HOME=str(temp / 'absent-cargo'))
    if case == 'broken-rustc':
        rustc.write_text('#!/bin/sh\nexit 17\n')
    mode = 'isolated-native-pinned' if case == 'unpinned' else 'isolated-native'
    candidate = temp / 'absent-generation' if case == 'missing' else alias
    run = subprocess.run(['bash', str(fixture_runner), mode, str(candidate)],
                         env=env, capture_output=True, text=True, timeout=15)
    if case == 'pass':
        assert run.returncode == 0, run.stderr
        assert marker.exists() and result.read_text() == str(old)
        assert alias.resolve() == new, 'fixture must retarget alias while old generation stays pinned'
    else:
        assert run.returncode != 0, case + ': invalid candidate accepted'
        assert not marker.exists() and not result.exists(), case + ': expensive work began before refusal'
        if case in ('missing-cargo', 'broken-rustc'):
            assert run.returncode == 2 and 'Rust toolchain preflight failed:' in run.stderr, run.stderr
    cargo.write_text('#!/bin/sh\nexit 0\n'); cargo.chmod(0o755)
    rustc.write_text('#!/bin/sh\nexit 0\n'); rustc.chmod(0o755)
    with lock.open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
alias.unlink(); alias.symlink_to(old)
marker.unlink(missing_ok=True); result.unlink(missing_ok=True)
with lock.open('a') as handle:
    fcntl.flock(handle, fcntl.LOCK_EX)
    process = subprocess.Popen(['bash', str(fixture_runner), 'isolated-native', str(alias)],
        env=dict(base, EXPECTED_ROOT=str(new)), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        try:
            stdout, stderr = process.communicate(timeout=0.2)
            raise AssertionError(('consumer did not wait for staging publication lock', stdout, stderr))
        except subprocess.TimeoutExpired:
            pass
        assert not marker.exists() and not result.exists()
        alias.unlink(); alias.symlink_to(new)
    finally:
        fcntl.flock(handle, fcntl.LOCK_UN)
        stdout, stderr = process.communicate(timeout=15)
    assert process.returncode == 0 and result.read_text() == str(new), (stdout, stderr)
print('Android operator generation consumer: locked selection, process pin, early lock release, immutable alias, stale/missing/unpinned refusal passed')
PY
fi
[[ "$suite" != generation ]] || exit 0
if [[ "$suite" == all ]]; then
python3 - "$ROOT/android/app/build.gradle.kts" "$TMP_ROOT" <<'PY'
import sys
from pathlib import Path
text, out = Path(sys.argv[1]).read_text(), Path(sys.argv[2])
needle = 'androidTestImplementation("androidx.test.espresso:espresso-intents:3.7.0")'
assert needle in text
for name, replacement in [('old', needle.replace('3.7.0', '3.6.1')),
                          ('preview', needle.replace('3.7.0', '3.7.0-alpha04')),
                          ('missing', ''), ('duplicate', needle + '\n' + needle)]:
    (out / ('espresso-' + name + '.kts')).write_text(text.replace(needle, replacement))
PY
bash "$runner" verify-native-dependencies
for fixture in "$TMP_ROOT"/espresso-*.kts; do
    if bash "$runner" verify-native-dependencies "$fixture" > "$TMP_ROOT/output" 2>&1; then
        echo "FAIL: incompatible API36 test dependency accepted: $fixture" >&2; exit 1
    fi
    grep -Fq 'API36 native tests require' "$TMP_ROOT/output"
done
echo 'Android API36 dependency guard: maintained version passed; old, preview, missing and ambiguous versions rejected'
python3 - "$runner" "$TMP_ROOT" <<'PY'
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

runner, temp = Path(sys.argv[1]), Path(sys.argv[2])
# Execute the maintained private-host lifecycle against real HTTP/process
# boundaries. Native execution is a stub here; these tests claim no JNI pass.
source = runner.read_text().split('if [[ "$mode" == isolated-native-child ]]; then', 1)[1]
child = source.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
operator = temp / 'operator'; (operator / 'apps/operator/dist-host').mkdir(parents=True)
bundle = operator / 'apps/operator/dist-host/hono-host.mjs'
native = temp / 'native.sh'
native.write_text('''#!/bin/bash
test "$1" = live && test "$3" = native || exit 93
test "$PAPERCUP_LIVE_BASE" = "$PAPERCUSP_OPERATOR_URL" || exit 94
exit "$NATIVE_TEST_EXIT"
''')
with tempfile.TemporaryDirectory(prefix='papercusp-test-runtime-') as runtime:
    home = Path(runtime) / 'home'; home.mkdir()
    lifecycle_cases = ['pass', 'native-fail', 'host-fail', 'ambient', 'wrong-url',
                       'wrong-home', 'existing-evidence', 'interrupt', 'wrong-counterpart']
    for case in lifecycle_cases:
        evidence = temp / case
        env = dict(os.environ, HOME=str(home), PAPERCUSP_WORKSPACE_ID='test-runtime-fixture',
            PAPERCUSP_BACKGROUND_WORKERS='0', PAPERCUSP_DBOS_ENABLE='0', PAPERCUSP_CLUSTER='0',
            PAPERCUSP_SKIP_PG_DISCOVERY='1', PAPERCUSP_BIND_HOST='127.0.0.1',
            PAPERCUP_OPERATOR_ROOT=str(operator), PAPERCUP_ANDROID_RUNNER=str(native),
            PAPERCUP_ANDROID_EVIDENCE=str(evidence), NATIVE_TEST_EXIT='17' if case=='native-fail' else '0')
        # The fake host has its own identity. An outer real-build pin must
        # not contaminate controls; test explicit pin refusal separately.
        env.pop('PAPERCUP_OPERATOR_SHA', None)
        if case == 'wrong-counterpart': env['PAPERCUP_OPERATOR_SHA'] = 'a' * 40
        import socket
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
        env.update(PAPERCUSP_HONO_PORT=str(port), PAPERCUSP_OPERATOR_URL=f'http://127.0.0.1:{port}')
        bundle.write_text('process.exit(31);' if case=='host-fail' else '''
import http from 'node:http';
http.createServer((req,res)=>{
 res.setHeader('Content-Type','application/json');
 res.end(JSON.stringify(req.url==='/api/health'
   ? {ok:true,service:'papercusp-operator',sha:'fixture'}
   : {current:process.env.PAPERCUSP_WORKSPACE_ID,workspaces:[{id:process.env.PAPERCUSP_WORKSPACE_ID}]}));
}).listen(Number(process.env.PAPERCUSP_HONO_PORT),'127.0.0.1');
''')
        if case=='ambient': env['PAPERCUSP_BACKGROUND_WORKERS']='1'
        if case=='wrong-url': env['PAPERCUSP_OPERATOR_URL']='http://public.example:3170'
        if case=='wrong-home': env['HOME']=str(temp)
        if case=='existing-evidence': evidence.mkdir(); (evidence/'owned').write_text('preserve')
        marker=temp/'native-started'
        if case=='interrupt':
            native.write_text('#!/bin/bash\ntouch "'+str(marker)+'"\nsleep 20\n')
        process = subprocess.Popen([sys.executable,'-c',child],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        if case=='interrupt':
            deadline=time.monotonic()+5
            # A waiting native child lets us interrupt after host readiness.
            while not marker.exists() and time.monotonic()<deadline:
                time.sleep(0.02)
            assert marker.exists(), 'native child never started'
            process.send_signal(signal.SIGTERM)
        stdout,stderr=process.communicate(timeout=8)
        proof_path=Path(str(evidence)+'-runtime')/'result.json'
        if case in ['ambient','wrong-url','wrong-home','existing-evidence']:
            assert process.returncode!=0 and not proof_path.exists(), (case,stderr)
        else:
            proof=json.loads(proof_path.read_text())
            assert proof['hostCleanupVerified'], (case,proof)
            assert (process.returncode==0)==(case=='pass'), (case,stdout,stderr,proof)
            assert proof['executionStarted']==(case in ['pass','native-fail','interrupt']), (case,proof)
            if proof['executionStarted']: assert proof['nativeProcessCleanupVerified'], (case,proof)
            if case=='native-fail': assert process.returncode==17
            with socket.socket() as sock:
                assert sock.connect_ex(('127.0.0.1',port))!=0, 'owned host survived cleanup'
        if case=='existing-evidence': assert (evidence/'owned').read_text()=='preserve'
print(f'Android private operator lifecycle: {len(lifecycle_cases)} launch/cleanup/refusal controls passed (native stub only)')
PY
python3 - "$runner" "$TMP_ROOT" <<'PY'
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys

runner, temp = Path(sys.argv[1]), Path(sys.argv[2])
expected = 'a' * 40
native = {'checkKind': 'native', 'exitCode': 0, 'executionStarted': True,
          'cleanupVerified': True, 'runId': 'this-attempt', 'runtime': 'http://127.0.0.1:34567',
          'ownedWorkspace': {'id': 'fixture-workspace'}, 'ownedDeviceIds': ['fixture-device'],
          'sourceFingerprints': {'tools/run-android-checks.sh': hashlib.sha256(runner.read_bytes()).hexdigest()}}
flags = ['journeyCompleted', 'authenticatedRequestPassed', 'returnedToPairedShell',
         'activityRecreated', 'valueRowLabelsPassed', 'enrollmentBrowserStubbed',
         'inboxScopedReadPassed', 'inboxRenderingPassed', 'inboxUnauthorizedPassed',
         'inboxRecoveryPassed', 'navigationPassed', 'credentialsCleared',
         'expiredJwtControlPassed', 'expiredJwtRejected', 'expiredJwtRenderingPassed',
         'expiredJwtFreshPairPassed', 'revokedDeviceRejected',
         'revokedDeviceRenderingPassed', 'revokedDeviceFreshPairPassed',
         'revocationMissingPromptBlocked', 'revocationDeniedPromptBlocked',
         'revocationApprovedPromptInvoked', 'revocationBiometricPromptStubbed']
native['nativeJourney'] = dict(runId='this-attempt', workspaceId='fixture-workspace',
                             deviceId='fixture-device', currentStage='completed', **{k: True for k in flags})
runtime = dict(exitCode=0, executionStarted=True, hostCleanupVerified=True,
               nativeProcessCleanupVerified=True, runtime=native['runtime'],
               workspaceId='test-runtime-fixture', operatorSourceCommit=expected, bundleSha256='b'*64,
               health={'sha': expected[:12]})
chat_xml = ('<testcase name="unauthorizedSendKeepsDraftWithoutInventingAPersistedTurn"/>'
            '<testcase name="forbiddenSendKeepsDraftWithoutInventingAPersistedTurn"/>')
recovery_xml = ''.join('<testcase name="'+name+'"/>' for name in (
    'rejectedDraftSurvivesSettingsRoundTrip', 'rejectedDraftSurvivesSameScopeRepairAndActivityRecreation',
    'repairToAnotherWorkspaceDoesNotExposePreviousDraft', 'repairToAnotherServerDoesNotExposePreviousDraft'))
good_xml = '<testsuite tests="8"><testcase name="launcherActivityStarts"/><testcase name="privateInboxScopeAcceptsOnlyDocumentedGlobalControls"/>' + chat_xml + recovery_xml + '</testsuite>'
cases = ['pass', 'stale-counterpart', 'missing-bundle', 'native-failed', 'host-failed',
         'native-not-executed', 'host-not-executed', 'native-cleanup', 'host-cleanup',
         'native-process-cleanup', 'ambient-runtime', 'runtime-mismatch', 'other-attempt',
         'other-workspace', 'other-device', 'stale-source', 'missing-fingerprints',
         'changed-apk', 'missing-apk', 'missing-xml', 'skipped-xml', 'duplicate-test',
         'stale-loaded-source', 'missing-loaded-source', 'missing-chat-tests',
         'skipped-chat-test', 'failed-chat-test'] + ['missing-'+f for f in flags] + [
         'missing-recovery', 'failed-recovery', 'skipped-recovery', 'duplicate-recovery']
for case in cases:
    out = temp / ('paired-proof-' + case); out.mkdir()
    reports = out / 'native-results'; reports.mkdir()
    host = Path(str(out)+'-runtime'); host.mkdir()
    n, r = copy.deepcopy(native), copy.deepcopy(runtime)
    n['artifacts'] = []
    for name in ('app-debug.apk', 'app-debug-androidTest.apk'):
        (out / name).write_bytes(b'tested fixture APK')
        n['artifacts'].append({'path': str(out/name), 'sha256': hashlib.sha256((out/name).read_bytes()).hexdigest()})
    xml = good_xml
    if case == 'stale-counterpart': r['operatorSourceCommit'] = 'c'*40
    if case == 'missing-bundle': r.pop('bundleSha256')
    if case == 'stale-loaded-source': r['health']['sha'] = 'c'*12
    if case == 'missing-loaded-source': r.pop('health')
    if case == 'native-failed': n['exitCode'] = 1
    if case == 'host-failed': r['exitCode'] = 1
    if case == 'native-not-executed': n['executionStarted'] = False
    if case == 'host-not-executed': r['executionStarted'] = False
    if case == 'native-cleanup': n['cleanupVerified'] = False
    if case == 'host-cleanup': r['hostCleanupVerified'] = False
    if case == 'native-process-cleanup': r['nativeProcessCleanupVerified'] = False
    if case == 'ambient-runtime': r['workspaceId'] = 'ambient'
    if case == 'runtime-mismatch': r['runtime'] = 'http://127.0.0.1:9999'
    if case == 'other-attempt': n['nativeJourney']['runId'] = 'old-attempt'
    if case == 'other-workspace': n['nativeJourney']['workspaceId'] = 'other'
    if case == 'other-device': n['nativeJourney']['deviceId'] = 'other'
    if case == 'stale-source': n['sourceFingerprints']['tools/run-android-checks.sh'] = 'd'*64
    if case == 'missing-fingerprints': n['sourceFingerprints'] = {}
    if case == 'changed-apk': (out/'app-debug.apk').write_bytes(b'other APK')
    if case == 'missing-apk': (out/'app-debug.apk').unlink()
    if case == 'skipped-xml': xml = good_xml.replace('name="launcherActivityStarts"/>', 'name="launcherActivityStarts"><skipped/></testcase>')
    if case == 'duplicate-test': xml = good_xml.replace('privateInboxScopeAcceptsOnlyDocumentedGlobalControls', 'launcherActivityStarts')
    if case == 'missing-chat-tests': xml = good_xml.replace(chat_xml, '')
    if case == 'skipped-chat-test': xml = good_xml.replace('name="forbiddenSendKeepsDraftWithoutInventingAPersistedTurn"/>', 'name="forbiddenSendKeepsDraftWithoutInventingAPersistedTurn"><skipped/></testcase>')
    if case == 'failed-chat-test': xml = good_xml.replace('name="unauthorizedSendKeepsDraftWithoutInventingAPersistedTurn"/>', 'name="unauthorizedSendKeepsDraftWithoutInventingAPersistedTurn"><failure>lost draft</failure></testcase>')
    if case == 'missing-recovery': xml = good_xml.replace(recovery_xml, '')
    if case == 'failed-recovery': xml = good_xml.replace('name="rejectedDraftSurvivesSettingsRoundTrip"/>', 'name="rejectedDraftSurvivesSettingsRoundTrip"><failure>lost draft</failure></testcase>')
    if case == 'skipped-recovery': xml = good_xml.replace('name="repairToAnotherWorkspaceDoesNotExposePreviousDraft"/>', 'name="repairToAnotherWorkspaceDoesNotExposePreviousDraft"><skipped/></testcase>')
    if case == 'duplicate-recovery': xml = good_xml.replace('repairToAnotherServerDoesNotExposePreviousDraft', 'repairToAnotherWorkspaceDoesNotExposePreviousDraft')
    if case.startswith('missing-') and case[8:] in flags: n['nativeJourney'].pop(case[8:])
    if case != 'missing-xml': (reports/'TEST-paired.xml').write_text(xml)
    (out/'result.json').write_text(json.dumps(n)); (host/'result.json').write_text(json.dumps(r))
    run = subprocess.run(['bash',str(runner),'verify-isolated-native',str(out),expected],capture_output=True,text=True,timeout=5)
    assert (run.returncode == 0) == (case == 'pass'), (case, run.stdout, run.stderr)
print(f'Android paired proof barrier: {len(cases)} acceptance/refusal controls passed (evidence fixtures only)')
PY
python3 - "$runner" "$TMP_ROOT" <<'PY'
import ast
import hashlib
import json
from pathlib import Path
import re
import sys
from types import SimpleNamespace
from urllib.error import HTTPError

runner, temp = Path(sys.argv[1]), Path(sys.argv[2])
live = runner.read_text().split('if [[ "$mode" == live ]]; then', 1)[1].split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
function = next(n for n in ast.parse(live).body if isinstance(n, ast.FunctionDef) and n.name == 'native_auth_fixture')
operator = temp / 'auth-operator'
signer = operator / 'packages/operator-core/lib/device-jwt.ts'
signer.parent.mkdir(parents=True); signer.write_text('private operator signer source fixture')
auth_cases = ['reject-401', 'reject-403', 'accepted-expiry', 'server-fault',
              'foreign-scope', 'bad-signer', 'control-reject-401', 'control-reject-403']
for case in auth_cases:
    minted, observed = [], []
    def api(path, method='GET', body=None, bearer=None):
        observed.append((path, method, bearer))
        if path.endswith('mint-pair-token'):
            return {'qrPayload': {'pairToken': 'private-one-use', 'workspaceId': 'owned-workspace'}}
        if path.endswith('/pair'):
            return {'deviceId': '12345678-1234-1234-1234-123456789abc',
                    'deviceToken': 'private-control-token',
                    'workspaceId': 'foreign' if case == 'foreign-scope' else 'owned-workspace'}
        assert path == '/api/device/attention'
        if bearer == 'private-control-token':
            if case.startswith('control-reject-'):
                raise HTTPError(path, int(case[-3:]), 'positive control refused', {}, None)
            return {'groups': []}
        assert bearer == 'header.expired.signature'
        if case == 'accepted-expiry': return {'groups': []}
        raise HTTPError(path, 500 if case == 'server-fault' else int(case[-3:]), 'auth refusal', {}, None)
    def run(command, **kwargs):
        assert command[:5] == ['node', '--import', 'tsx', '--input-type=module', '-e']
        assert 'signDeviceToken' in command[-1] and 'verifyDeviceToken' in command[-1]
        assert 'finally { Date.now = realNow; }' in command[-1]
        assert kwargs['cwd'] == operator and kwargs['capture_output'] and kwargs['check']
        assert json.loads(kwargs['input'])['controlToken'] == 'private-control-token'
        return SimpleNamespace(stdout='not-jwt' if case == 'bad-signer' else 'header.expired.signature')
    result = {'ownedDeviceIds': []}
    scope = dict(api=api, native_pair_tokens=minted, fixture_id='owned-workspace', existing_devices=set(),
        result=result, re=re, Path=Path, os=SimpleNamespace(environ={'PAPERCUP_OPERATOR_ROOT': str(operator)}),
        subprocess=SimpleNamespace(run=run), json=json, HTTPError=HTTPError, hashlib=hashlib)
    exec(compile(ast.Module(body=[function], type_ignores=[]), str(runner), 'exec'), scope)
    try:
        fixture = scope['native_auth_fixture'](34567)
    except (RuntimeError, HTTPError):
        assert case not in ['reject-401', 'reject-403'], case
        if case.startswith('control-reject-'):
            assert result['authFixtureStage'] == 'positive-control'
            assert 'authFixtureBasis' not in result
    else:
        assert case in ['reject-401', 'reject-403'], case
        assert result['authFixtureBasis']['expiredRejectedStatus'] == int(case[-3:])
        assert result['authFixtureBasis']['controlAccepted']
        assert len(minted) == 3 and len(result['ownedDeviceIds']) == 1
        assert fixture['expiredToken'] == 'header.expired.signature'
        assert 'private-control-token' not in json.dumps(result)
        assert 'header.expired.signature' not in json.dumps(result)
print(f'Android auth fixture: {len(auth_cases)} control/refusal cases passed (signer and API fixtures only)')
PY
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

fi
if [[ "$suite" == all || "$suite" == live ]]; then
# Exercise the live runner through actual HTTP and subprocess boundaries.
# The fake Cargo process is deliberately separate from the fixture server:
# skipped/empty exits, failed tests and interruption must all clean only the
# resources created for this attempt, without changing desktop selection.
python3 - "$runner" "$TMP_ROOT" "${2:-}" <<'PY'
# Upper bound for one stubbed live-runner invocation (see its use below).
STUB_HANG_TIMEOUT_SEC = 120
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
         'native-unused-token', 'native-wrong-device', 'native-existing-files', 'native-missing-serial',
         'native-install-fail', 'native-install-incompatible']
if sys.argv[3]:
    assert sys.argv[3] in cases, 'Unknown live fixture case: ' + sys.argv[3]
    cases = [sys.argv[3]]
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
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/LibraryNoticesScreen.kt',
                         'android/app/src/main/res/values/strings.xml',
                         'android/build.gradle.kts',
                         'tools/tests/android-library-notices-test.sh',
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/DiagnosticsScreen.kt',
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/MainActivity.kt',
                         'android/app/src/main/AndroidManifest.xml',
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/PapercupApplication.kt',
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/InboxScreen.kt',
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/CompanionFeed.kt',
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/Credentials.kt',
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/HumanError.kt',
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/PairScreen.kt',
                         'android/app/src/main/kotlin/com/papercuspai/operator/mobile/OperatorChatScreen.kt',
                         'android/app/src/androidTest/kotlin/com/papercuspai/operator/mobile/PapercupAppSmokeTest.kt',
                         'android/app/src/androidTest/kotlin/com/papercuspai/operator/mobile/OperatorChatScreenTest.kt',
                         'android/app/src/androidTest/kotlin/com/papercuspai/operator/mobile/LibraryNoticesScreenTest.kt',
                         'android/app/src/test/kotlin/com/papercuspai/operator/mobile/LibraryNoticesTest.kt',
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
import atexit, json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
case = os.environ['TEST_LIVE_CASE']
# Retain readiness command entry/exit separately from the parent deadline.
# Record only preflight commands; pairing inputs never enter this ledger.
readiness = args in (['devices'], ['devices', '-l']) or (
    args[:3] == ['-s', 'emulator-5556', 'shell'] and
    len(args) > 3 and args[3] in ('getprop', 'pidof', 'settings', 'cat', 'df', 'getconf')) or (
    args == ['-s', 'emulator-5556', 'logcat', '-b', 'crash', '-d'])
if readiness:
    def trace(phase):
        row = dict(phase=phase, pid=os.getpid(), args=args,
                   monotonicNs=time.monotonic_ns(), wallNs=time.time_ns())
        fd = os.open('fake-adb-readiness.jsonl', os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try: os.write(fd, (json.dumps(row) + '\\n').encode())
        finally: os.close(fd)
    trace('start')
    atexit.register(trace, 'end')
if args in (['devices'], ['devices', '-l']):
    print('List of devices attached\\nemulator-5556 device')
    sys.exit(0)
assert args[:2] == ['-s', 'emulator-5556']
args = args[2:]
private = Path('private-fixture.json')
if args == ['shell', 'getprop', 'sys.boot_completed']: print('1')
elif args == ['shell', 'getprop', 'ro.build.version.sdk_full']:
    print('unmeasured' if os.environ.get('TEST_LIVE_BOOT_CASE') == 'sdk-unmeasured' else '36')
elif args == ['shell', 'getprop', 'ro.build.version.sdk']: print('36')
elif args == ['shell', 'cat', '/proc/meminfo']:
    print('MemTotal: 4008624 kB\\nMemAvailable: 2831424 kB')
elif args == ['shell', 'df', '-k', '/data']:
    print('Filesystem 1K-blocks Used Available Use% Mounted on\\n/dev/block/test 1048576 0 1048576 0% /data')
elif args == ['shell', 'getconf', 'PAGE_SIZE']: print('4096' if case == 'native-preflight-fail' else '16384')
elif args[:2] == ['shell', 'pidof']: print('123')
elif args == ['shell', 'settings', 'get', 'global', 'airplane_mode_on']: print('0')
elif args == ['logcat', '-b', 'crash', '-d']: pass
elif args[:2] == ['logcat', '-d']:
    if case != 'native-no-pairing-trace':
        for stage in ['client-start', 'client-ready', 'request-start', 'response-received', 'credentials-saved']:
            print('1.0 I PapercupPairing: stage=' + stage)
elif args[:2] == ['reverse', '--list']: pass
elif args[:2] == ['reverse', '--remove']:
    if case == 'native-local-cleanup-fail': sys.exit(1)
elif args and args[0] == 'install':
    if case == 'native-install-fail':
        print('Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]', file=sys.stderr); sys.exit(1)
    if case == 'native-install-incompatible' and not Path('incompatible-removed').exists():
        print('Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match]'); sys.exit(1)
    print('Success')
elif args and args[0] == 'uninstall':
    assert case == 'native-install-incompatible', ('uninstall outside an incompatible install', case)
    if args[1:] == ['com.papercuspai.operator.mobile']: Path('incompatible-removed').touch()
    print('Success')
elif args and args[0] == 'reverse': pass
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
    assert any('com.papercuspai.operator.mobile.OperatorChatScreenTest' in arg for arg in sys.argv)
    assert all('private-test-token' not in arg for arg in sys.argv)
    if case == 'native-timeout': time.sleep(5)
    p = Path('android/app/build/outputs/androidTest-results/connected/debug/TEST-native.xml')
    p.parent.mkdir(parents=True, exist_ok=True)
    journey = '<testcase name="launcherActivityStarts"/>'
    scope = '<testcase name="privateInboxScopeAcceptsOnlyDocumentedGlobalControls"/>'
    chat = ('<testcase name="unauthorizedSendKeepsDraftWithoutInventingAPersistedTurn"/>'
            '<testcase name="forbiddenSendKeepsDraftWithoutInventingAPersistedTurn"/>')
    chat += ''.join('<testcase name="'+name+'"/>' for name in (
        'rejectedDraftSurvivesSettingsRoundTrip', 'rejectedDraftSurvivesSameScopeRepairAndActivityRecreation',
        'repairToAnotherWorkspaceDoesNotExposePreviousDraft', 'repairToAnotherServerDoesNotExposePreviousDraft'))
    if case == 'native-no-scope-test': scope = ''
    if case == 'native-duplicate-journey': scope = journey
    if case == 'native-wrong-scope-test': scope = '<testcase name="unrelatedTest"/>'
    if case == 'native-skipped-scope-test':
        scope = '<testcase name="privateInboxScopeAcceptsOnlyDocumentedGlobalControls"><skipped/></testcase>'
    p.write_text('<testsuite tests="0"/>' if case == 'native-empty' else
                 '<testsuite tests="8" failures="1"><testcase name="launcherActivityStarts"><failure>lifecycle failure</failure></testcase>' + scope + chat + '</testsuite>' if case == 'native-test-fail' else
                 '<testsuite tests="8">' + journey + scope + chat + '</testsuite>')
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
        # A hang detector, not a performance budget: native stub cases measured
        # 3.8-7.8s at load ~194/128 cores (WI-10006927), and a fixed 15s failed
        # isolated-native preflight under fleet load. Timeout behaviour itself is
        # asserted through PAPERCUP_LIVE_TIMEOUT_SEC=1 inside the runner.
        run = subprocess.run(['bash', selected_runner, 'live', str(evidence), 'native' if native_mode else 'rust'], env=env,
                             capture_output=True, text=True, timeout=STUB_HANG_TIMEOUT_SEC)
        result = json.loads((evidence / 'result.json').read_text())
        # The EXIT trap removes the fixture tree. Surface readiness evidence
        # before cleanup rather than losing the reason behind an early refusal.
        boot_proof = evidence / 'emulator-preflight/emulator-boot.json'
        readiness = json.loads(boot_proof.read_text()) if boot_proof.exists() else None
        diagnostic = (case, run.stdout[-1500:], run.stderr[-1500:], result, readiness)
        if case == 'native-preflight-fail':
            # Its 4-KiB page refusal occurs before the boot-health subprocess.
            assert readiness is None and result['errors'] == ['native live emulator must be booted API36 with 16KB pages'], diagnostic
        if native_mode and case not in ('native-preflight-fail', 'native-existing-files', 'native-missing-serial'):
            # A negative journey control must reach its intended predicate.
            # A readiness timeout is a fixture failure, never acceptance proof.
            assert readiness and readiness['frameworkReady'], ('native fixture failed readiness', diagnostic)
            rows = [json.loads(line) for line in (native_root / 'fake-adb-readiness.jsonl').read_text().splitlines()]
            starts = {row['pid']: row for row in rows if row['phase'] == 'start'}
            ends = {row['pid']: row for row in rows if row['phase'] == 'end'}
            assert starts.keys() == ends.keys(), ('unfinished fake ADB command', rows)
            assert all(ends[pid]['monotonicNs'] >= row['monotonicNs'] for pid, row in starts.items())
        assert (run.returncode == 0) == (case in ('pass', 'native-pass', 'native-install-incompatible')), diagnostic
        assert state['current'] == 'original'
        assert result['checkKind'] == ('native' if native_mode else 'rust')
        assert len(result['runId']) == 32
        if case not in ('setup-unavailable', 'setup-no-selection', 'native-preflight-fail', 'native-existing-files', 'native-missing-serial', 'native-install-fail'):
            assert (result['ownedWorkspace'] or {}).get('name', '').startswith('android-live-scope-'), diagnostic
        else:
            assert result['ownedWorkspace'] is None
        assert state['devices'] == [{'device_id': original_device}], state
        if case in ('cleanup-fail', 'native-cleanup-fail'):
            assert not result['cleanupVerified'] and len(state['workspaces']) == 2
        else:
            assert result['cleanupVerified'] == (case not in ('native-local-cleanup-fail', 'native-uninstalled')), (case, result)
            assert state['workspaces'] == [{'id': 'original', 'name': 'Original'}], (case, result, state)
        if case in ('setup-unavailable', 'setup-no-selection', 'preflight-fail', 'native-preflight-fail', 'native-existing-files', 'native-missing-serial', 'native-install-fail'):
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
        if case == 'native-install-fail':
            # Native preflight runs after the workspace check, so like the
            # other native-* preflight refusals it is an unstarted run, not setupFailed.
            assert not result['executionStarted'] and not result.get('replacedIncompatiblePackage'), result
            assert any('INSTALL_FAILED_INSUFFICIENT_STORAGE' in error for error in result['errors']), result['errors']
        if case == 'native-install-incompatible':
            assert result['replacedIncompatiblePackage'] is True, result
            assert result['nativeJourney']['journeyCompleted'] is True
        if case == 'native-pass':
            assert result['nativeJourney']['journeyCompleted'] is True
            assert 'replacedIncompatiblePackage' not in result, result
            assert len(result['artifacts']) == 2
            assert result['ownedDeviceIds'] == [device]
        if case == 'native-test-fail':
            xml = evidence / 'native-results/TEST-native.xml'
            assert '<failure>lifecycle failure</failure>' in xml.read_text(), 'failed native evidence was discarded'
            assert len(result['artifacts']) == 2, 'failed run lost its exact APKs'
            assert result['nativeObservedProof']['failedStage'] == 'persisted-credentials', 'failure-stage witness was discarded'
        if case == 'native-duplicate-journey':
            assert any('native journey and scope controls must each execute exactly once' in error
                       for error in result['errors']), diagnostic
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
    capture_output=True, text=True, timeout=STUB_HANG_TIMEOUT_SEC)
failure = json.loads((offline / 'result.json').read_text())
assert run.returncode != 0 and failure['exitCode'] != 0
assert failure['setupFailed'] and failure['setupFailureClass'] == 'URLError'
assert not failure['executionStarted'] and failure['ownedWorkspace'] is None
assert failure['ownedDeviceIds'] == [] and failure['cleanupVerified']
assert failure['errors'] and failure['finishedAt']
print(f'Android live fixture guards: {len(cases) + 2} passed; Rust/native ownership, executed proof and independent cleanup verified')
PY
fi
[[ "$suite" != live ]] || exit 0
# The negative journey case must fail the suite when an unrelated readiness
# predicate fails. Keep its command ledger inspectable until this guard checks it.
if [[ "$suite" == all ]]; then
    if TEST_LIVE_BOOT_CASE=sdk-unmeasured bash "${BASH_SOURCE[0]}" live native-duplicate-journey \
        > "$TMP_ROOT/live-readiness-refusal.txt" 2>&1; then
        echo 'FAIL: unrelated readiness failure accepted as a negative journey control' >&2; exit 1
    fi
    python3 - "$TMP_ROOT/live-readiness-refusal.txt" "$TMP_ROOT" <<'PY'
import json, shutil, sys
from pathlib import Path
output = Path(sys.argv[1]).read_text()
assert 'native fixture failed readiness' in output, output
retained = Path(output.split('retained evidence: ')[-1].strip())
assert retained.parent == Path(sys.argv[2]).parent and retained.name.startswith('runner-fixtures.')
boot = json.loads((retained / 'live-evidence-native-duplicate-journey/emulator-preflight/emulator-boot.json').read_text())
assert boot['frameworkErrors'] == ['Native SDK version is unmeasured'], boot
rows = [json.loads(line) for line in (retained / 'native-root-native-duplicate-journey/fake-adb-readiness.jsonl').read_text().splitlines()]
sdk = [row for row in rows if row['args'][-1] == 'ro.build.version.sdk_full']
assert [row['phase'] for row in sdk] == ['start', 'end'], sdk
assert sdk[0]['pid'] == sdk[1]['pid'] and sdk[0]['monotonicNs'] <= sdk[1]['monotonicNs']
shutil.rmtree(retained)
PY
    echo 'Android live fixture diagnostic guard: unrelated SDK refusal rejected with retained command evidence'
fi
if [[ "$suite" == all ]]; then
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
# Runner space release deletes preinstalled software as root, so it must refuse
# every machine except the disposable hosted runner before any deletion.
cat > "$TMP_ROOT/bin/sudo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_SUDO_LOG"
SH
chmod +x "$TMP_ROOT/bin/sudo"
for env_pair in 'false github-hosted' 'true self-hosted'; do
    read -r actions runner_env <<< "$env_pair"
    if GITHUB_ACTIONS="$actions" RUNNER_ENVIRONMENT="$runner_env" TEST_SUDO_LOG="$TMP_ROOT/sudo-refused" \
        PATH="$TMP_ROOT/bin:$PATH" bash "$runner" release-runner-space "$TMP_ROOT/space-refused" > "$TMP_ROOT/output" 2>&1; then
        echo "FAIL: runner space release admitted $env_pair" >&2
        exit 1
    fi
    [[ ! -e "$TMP_ROOT/sudo-refused" ]] || { echo 'FAIL: refused runner space release still deleted' >&2; exit 1; }
done
GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted TEST_SUDO_LOG="$TMP_ROOT/sudo-hosted" \
    PATH="$TMP_ROOT/bin:$PATH" bash "$runner" release-runner-space "$TMP_ROOT/space-attempt"
[[ "$(grep -c '^release-runner-space \(before\|after\) ' "$TMP_ROOT/space-attempt/storage.txt")" == 2 ]]
if [[ -s "$TMP_ROOT/sudo-hosted" ]]; then
    if grep -Ev '^rm -rf --one-file-system /(usr/share/dotnet|usr/local/\.ghcup|opt/ghc|usr/share/swift|opt/hostedtoolcache/(CodeQL|PyPy|go)|usr/local/share/(powershell|boost|chromium)|usr/local/julia[^/]*|opt/(microsoft|google|az))$' "$TMP_ROOT/sudo-hosted"; then
        echo 'FAIL: runner space release deleted outside the unused-toolchain set' >&2
        exit 1
    fi
fi
echo 'Android runner space release guards: 3 passed'

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
printf 'hw.ramSize=4096\n' > "$TMP_ROOT/avd-memory.ini"
ANDROID_HOME="$TMP_ROOT/sdk" PATH="$TMP_ROOT/bin:$PATH" bash "$runner" verify-emulator \
    "$TMP_ROOT/emulator-memory-pass" 5582 "$TMP_ROOT/avd-memory.ini"
grep -Fq '"memoryMiB": 4096' "$TMP_ROOT/emulator-memory-pass/emulator-memory.json"
for memory in 4096M 1536 256 '' -1 0 '4096junk'; do
    printf 'hw.ramSize=%s\n' "$memory" > "$TMP_ROOT/avd-memory.ini"
    if ANDROID_HOME="$TMP_ROOT/sdk" PATH="$TMP_ROOT/bin:$PATH" bash "$runner" verify-emulator \
        "$TMP_ROOT/emulator-memory-rejected" 5582 "$TMP_ROOT/avd-memory.ini" > "$TMP_ROOT/output" 2>&1; then
        echo "FAIL: invalid or undersized guest RAM accepted: $memory" >&2; exit 1
    fi
    grep -Fq '"sufficient": false' "$TMP_ROOT/emulator-memory-rejected/emulator-memory.json"
done
for config in missing duplicate; do
    if [[ "$config" == missing ]]; then
        printf 'hw.cpu.ncore=4\n' > "$TMP_ROOT/avd-memory.ini"
    else
        printf 'hw.ramSize=4096\nhw.ramSize=256\n' > "$TMP_ROOT/avd-memory.ini"
    fi
    if ANDROID_HOME="$TMP_ROOT/sdk" PATH="$TMP_ROOT/bin:$PATH" bash "$runner" verify-emulator \
        "$TMP_ROOT/emulator-memory-rejected" 5582 "$TMP_ROOT/avd-memory.ini" > "$TMP_ROOT/output" 2>&1; then
        echo "FAIL: ambiguous guest RAM accepted: $config" >&2; exit 1
    fi
done
echo 'Android guest RAM guards: integer MiB accepted; suffix, undersized, missing and duplicate allocations rejected'
for port in 5554 5584; do
    ANDROID_HOME="$TMP_ROOT/sdk" PATH="$TMP_ROOT/bin:$PATH" bash "$runner" verify-emulator "$TMP_ROOT/valid-port-$port" "$port"
done
for port in 5553 5555 5586 5596 invalid; do
    if ANDROID_HOME="$TMP_ROOT/sdk" PATH="$TMP_ROOT/bin:$PATH" bash "$runner" verify-emulator "$TMP_ROOT/invalid-port-$port" "$port" > "$TMP_ROOT/output" 2>&1; then
        echo "FAIL: unsupported emulator discovery port accepted: $port" >&2
        exit 1
    fi
done
fi
mkdir -p "$TMP_ROOT/boot-bin"
cat > "$TMP_ROOT/boot-bin/adb" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == '-s emulator-5584 shell getprop sys.boot_completed' ]]; then
    if [[ "${TEST_BOOT_READY:-0}" == 1 ]]; then printf '1\r\n'; else echo 'error: device not found' >&2; exit 1; fi
elif [[ "$*" == 'devices -l' ]]; then
    printf 'List of devices attached\n'
elif [[ "$*" == *'shell cat /proc/meminfo' ]]; then
    case "${TEST_BOOT_CASE:-}" in
        memory-read-fail) exit 224 ;;
        memory-malformed) printf 'MemTotal: unknown\nMemAvailable: 2831424 kB\n' ;;
        memory-missing) printf 'MemTotal: 4008624 kB\n' ;;
        memory-duplicate) printf 'MemTotal: 4008624 kB\nMemTotal: 4008624 kB\nMemAvailable: 2831424 kB\n' ;;
        memory-small) printf 'MemTotal: 1470000 kB\nMemAvailable: 1000000 kB\n' ;;
        memory-low-available) printf 'MemTotal: 4008624 kB\nMemAvailable: 1572863 kB\n' ;;
        memory-low-total) printf 'MemTotal: 3670015 kB\nMemAvailable: 2831424 kB\n' ;;
        memory-boundary) printf 'MemTotal: 3670016 kB\nMemAvailable: 1572864 kB\n' ;;
        *) printf 'MemTotal: 4008624 kB\nMemAvailable: 2831424 kB\n' ;;
    esac
elif [[ "$*" == *'shell pidof '* ]]; then
    if [[ "${TEST_BOOT_CASE:-}" == missing ]]; then exit 1; fi
    if [[ "${TEST_BOOT_CASE:-}" == restart ]]; then
        value="$(cat "$TEST_BOOT_COUNTER" 2>/dev/null || echo 100)"
        echo "$((value + 1))" > "$TEST_BOOT_COUNTER"
        echo "$value"
    else echo 100; fi
elif [[ "$*" == *'shell settings get global airplane_mode_on' ]]; then
    if [[ "${TEST_BOOT_CASE:-}" == settings ]]; then echo 'Broken pipe' >&2; exit 224; fi
    echo 0
elif [[ "$*" == *'logcat -b crash -d' ]]; then
    if [[ "${TEST_BOOT_CASE:-}" == crash ]]; then
        echo 'Fatal signal 6 (SIGABRT) in tid 843 (RegionSampling), pid 762 (surfaceflinger)'
        echo "Abort message: 'Assertion failed: !rcEnc->featureInfo()->hasReadColorBufferDma'"
    fi
elif [[ "$*" == *'shell getprop ro.build.version.sdk_full' ]]; then
    if [[ "${TEST_BOOT_CASE:-}" == sdk-fallback ]]; then echo; else echo 36.1; fi
elif [[ "$*" == *'shell getprop ro.build.version.sdk' ]]; then
    echo 36
elif [[ "$*" == *'shell dumpsys -t 3 SurfaceFlinger' ]]; then
    [[ "${TEST_BOOT_CASE:-}" != sdk-fallback ]] || exit 91
    if [[ "${TEST_BOOT_CASE:-}" == graphics-missing ]]; then
        echo 'GLES: GL_EXT_buffer_storage'
    elif [[ "${TEST_BOOT_CASE:-}" == graphics-partial ]]; then
        echo 'ANDROID_EMU_read_color_buffer_dma_suffix ANDROID_EMU_direct_mem'
    else
        echo 'ANDROID_EMU_read_color_buffer_dma ANDROID_EMU_direct_mem ANDROID_EMU_has_shared_slots_host_memory_allocator'
    fi
elif [[ "$*" == *'shell df -k /data' ]]; then
    [[ "${TEST_BOOT_CASE:-}" != storage-read-fail ]] || exit 224
    echo 'Filesystem 1K-blocks Used Available Use% Mounted on'
    if [[ "${TEST_BOOT_CASE:-}" == storage-unknown ]]; then echo unavailable
    elif [[ "${TEST_BOOT_CASE:-}" == storage-full ]]; then echo '/dev/block/dm-55 792608 755268 4572 100% /data/user/0'
    elif [[ "${TEST_BOOT_CASE:-}" == storage-small ]]; then echo '/dev/block/test 1048576 524289 524287 50% /data'
    else echo '/dev/block/test 1048576 524288 524288 50% /data'; fi
else
    echo "unexpected boot fixture command: $*" >&2; exit 1
fi
SH
chmod +x "$TMP_ROOT/boot-bin/adb"
TEST_BOOT_READY=1 PATH="$TMP_ROOT/boot-bin:$PATH" bash "$runner" verify-emulator-boot emulator-5584 "$TMP_ROOT/boot-pass" 1
for case in missing restart settings crash graphics-missing graphics-partial storage-full storage-small storage-unknown storage-read-fail memory-read-fail memory-malformed memory-missing memory-duplicate memory-small memory-low-available memory-low-total; do
    if TEST_BOOT_READY=1 TEST_BOOT_CASE="$case" TEST_BOOT_COUNTER="$TMP_ROOT/boot-counter" \
        PATH="$TMP_ROOT/boot-bin:$PATH" bash "$runner" verify-emulator-boot emulator-5584 \
        "$TMP_ROOT/boot-$case" 1 > "$TMP_ROOT/output" 2>&1; then
        echo "FAIL: sticky boot flag admitted unhealthy framework: $case" >&2; exit 1
    fi
done
TEST_BOOT_READY=1 TEST_BOOT_CASE=sdk-fallback PATH="$TMP_ROOT/boot-bin:$PATH" \
    bash "$runner" verify-emulator-boot emulator-5584 "$TMP_ROOT/boot-sdk-fallback" 1
TEST_BOOT_READY=1 TEST_BOOT_CASE=memory-boundary PATH="$TMP_ROOT/boot-bin:$PATH" \
    bash "$runner" verify-emulator-boot emulator-5584 "$TMP_ROOT/boot-memory-boundary" 1
if PATH="$TMP_ROOT/boot-bin:$PATH" bash "$runner" verify-emulator-boot emulator-5584 "$TMP_ROOT/boot-fail" 1 > "$TMP_ROOT/output" 2>&1; then
    echo 'FAIL: missing ADB transport accepted as a booted emulator' >&2; exit 1
fi
python3 - "$TMP_ROOT" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
assert json.loads((root / 'boot-pass/emulator-boot.json').read_text())['bootCompleted'] is True
assert json.loads((root / 'boot-pass/emulator-boot.json').read_text())['frameworkReady'] is True
good = json.loads((root / 'boot-pass/emulator-boot.json').read_text())
assert good['guestMemory']['sufficient'] and good['guestMemory']['totalKiB'] == 4008624
assert json.loads((root / 'boot-memory-boundary/emulator-boot.json').read_text())['guestMemory']['sufficient']
assert good['graphics']['missingExtensions'] == []
assert good['guestStorage']['availableBytes'] == good['guestStorage']['requiredBytes']
fallback = json.loads((root / 'boot-sdk-fallback/emulator-boot.json').read_text())
assert fallback['frameworkReady'] and not fallback['graphics']['dmaReadbackRequired']
for case in ['missing', 'restart', 'settings', 'crash', 'graphics-missing', 'graphics-partial',
             'storage-full', 'storage-small', 'storage-unknown', 'storage-read-fail',
             'memory-read-fail', 'memory-malformed', 'memory-missing', 'memory-duplicate',
             'memory-small', 'memory-low-available', 'memory-low-total']:
    proof = json.loads((root / f'boot-{case}/emulator-boot.json').read_text())
    assert proof['bootCompleted'] and not proof['frameworkReady'] and proof['frameworkErrors']
    # A refusal alone can hide a fixture timeout before its intended predicate.
    expected = {
        'missing': "('shell', 'pidof', 'surfaceflinger'): exit 1:",
        'restart': 'Native framework restarted',
        'settings': "('shell', 'settings', 'get', 'global', 'airplane_mode_on'): exit 224:",
        'crash': 'Native framework crash detected',
        'graphics-missing': 'Native graphics lacks DMA readback',
        'graphics-partial': 'Native graphics lacks DMA readback',
        'storage-full': 'Insufficient native userdata space',
        'storage-small': 'Insufficient native userdata space',
        'storage-unknown': 'Native userdata free space is unmeasured',
        'storage-read-fail': "('shell', 'df', '-k', '/data'): exit 224:",
        'memory-read-fail': "('shell', 'cat', '/proc/meminfo'): exit 224:",
        'memory-malformed': 'Native guest memory is unmeasured: MemTotal',
        'memory-missing': 'Native guest memory is unmeasured: MemAvailable',
        'memory-duplicate': 'Native guest memory is unmeasured: MemTotal',
        'memory-small': 'Insufficient native guest memory',
        'memory-low-available': 'Insufficient native guest memory',
        'memory-low-total': 'Insufficient native guest memory',
    }[case]
    assert len(proof['frameworkErrors']) == 1 and expected in proof['frameworkErrors'][0], \
        (case, expected, proof['frameworkErrors'])
bad = json.loads((root / 'boot-fail/emulator-boot.json').read_text())
assert bad['bootCompleted'] is False and 'device not found' in bad['adbError']
assert (root / 'boot-fail/boot-transports.txt').is_file()
PY
echo 'Android native readiness: healthy, memory boundary and API36 fallback accepted; 17 process/service/crash/graphics/userdata/memory controls rejected'
[[ "$suite" != boot ]] || exit 0
# Prove the failed-positive path leaves inspectable evidence and prints its
# actual predicate; the nested boot suite stops at its first memory refusal.
if TEST_BOOT_CASE=memory-small bash "${BASH_SOURCE[0]}" boot > "$TMP_ROOT/retention-output" 2>&1; then
    echo 'FAIL: deliberately unhealthy positive boot fixture passed' >&2; exit 1
fi
python3 - "$TMP_ROOT/retention-output" "$TMP_ROOT" <<'PY'
import json, shutil, sys
from pathlib import Path
output = Path(sys.argv[1]).read_text()
assert 'Owned emulator is not healthy: Insufficient native guest memory' in output, output
retained = [line.partition('retained evidence: ')[2] for line in output.splitlines()
            if 'retained evidence: ' in line]
assert len(retained) == 1, output
root = Path(retained[0])
assert root.parent == Path(sys.argv[2]).parent and root.name.startswith('runner-fixtures.')
proof = json.loads((root / 'boot-pass/emulator-boot.json').read_text())
assert not proof['frameworkReady'] and not proof['guestMemory']['sufficient']
shutil.rmtree(root)
PY
echo 'Android runner failure evidence: exact positive-fixture predicate and JSON retained'
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

# The native Rust + Gradle build owns its own budget, separate from the
# live-smoke PAPERCUP_LIVE_TIMEOUT_SEC (a cold four-ABI Cargo cache exceeds
# 240s). Out-of-range budgets are refused before any build or network call.
for bad_budget in 59 7201; do
    if PAPERCUP_LIVE_BASE=http://127.0.0.1:9 PAPERCUP_NATIVE_BUILD_TIMEOUT_SEC="$bad_budget" \
        bash "$runner" live "$TMP_ROOT/build-budget-$bad_budget" native > "$TMP_ROOT/output" 2>&1; then
        echo "FAIL: native build timeout $bad_budget was accepted" >&2
        exit 1
    fi
    grep -Fq 'native build timeout must be between 60 and 7200 seconds' "$TMP_ROOT/output"
done
# Both build subprocesses (assemble + test APK) use the build budget, not the
# live timeout, and the isolated wrapper waits at least test allowance + budget.
if [[ "$(grep -c 'check=True, timeout=build_timeout)' "$runner")" != 2 ]]; then
    echo 'FAIL: native build steps do not both use the dedicated build timeout' >&2
    exit 1
fi
grep -Fq 'native.wait(timeout=1800 + native_build_budget)' "$runner"
echo 'Android native build budget: out-of-range budgets rejected; build steps and isolated wrapper use the dedicated budget'

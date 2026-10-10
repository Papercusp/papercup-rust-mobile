#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Reuse the maintained Rust, build, privacy and installer checks. A green
# Gradle exit with zero, skipped or stale test results is not a verified run.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Hold the same executor for complete check/native journeys, including their
# shared build products and evidence. Nested build calls inherit this lease.
case "${1:-full}" in
    host|full|connected|sealed-native|live|isolated-native|isolated-native-pinned|isolated-native-child|cloud-native)
        if [[ -z "${PAPERCUP_ANDROID_EXECUTOR_FD:-}" ]]; then
            exec python3 tools/android-ci.py --exclusive-command bash "$0" "$@"
        fi
        JAVA_TOOL_OPTIONS="$(python3 tools/android-ci.py --verify-executor --java-tool-options)"
        export JAVA_TOOL_OPTIONS
        ;;
esac

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

resolve_rust_toolchain() {
    # Preserve explicit toolchain homes across the private runtime's HOME.
    export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
    export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
    if ! command -v cargo >/dev/null 2>&1; then
        export PATH="$CARGO_HOME/bin:$PATH"
    fi
    local tool
    for tool in cargo rustc; do
        if ! command -v "$tool" >/dev/null 2>&1 || ! "$tool" --version; then
            echo "Rust toolchain preflight failed: $tool unavailable or unusable (CARGO_HOME=$CARGO_HOME)" >&2
            return 2
        fi
    done
}

# Early native modes use the same maintained SDK environment as host/connected.
ANDROID_HOME="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"
ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_HOME ANDROID_SDK_ROOT
export PATH="$ANDROID_HOME/platform-tools:$PATH"

mode="${1:-full}"
if [[ "$mode" == cloud-native ]]; then
    resolve_rust_toolchain
    exec python3 tools/cloud-native-check.py "${2:?fresh evidence directory is required}" "${3:?private fresh QR file is required}"
fi
if [[ "$mode" == sealed-native ]]; then
    export PAPERCUP_SEALED_NATIVE_OUT="${2:?fresh evidence directory is required}"
    export PAPERCUP_SEALED_OPERATOR_ROOT="${3:-${PAPERCUP_PAPERCUSP_ROOT:-$ROOT/../papercusp}}"
    export PAPERCUP_SEALED_NATIVE_SELECTION="${4:-interop}"
    JAVA_HOME="$(bash tools/build-scripts/resolve-java-home.sh)"
    export JAVA_HOME
    python3 - <<'PY'
import base64, hashlib, json, os, select, shutil, subprocess
from pathlib import Path
from urllib.parse import urlparse

serial = os.environ.get('ANDROID_SERIAL', '')
if not serial.startswith('emulator-') or not serial[9:].isdigit():
    raise SystemExit('sealed-native requires an explicitly owned emulator in ANDROID_SERIAL')
operator = Path(os.environ['PAPERCUP_SEALED_OPERATOR_ROOT']).resolve()
for dependency in ('tsx', 'ws', '@hyperswarm/secret-stream'):
    if not (operator / 'node_modules' / dependency / 'package.json').is_file():
        raise SystemExit('Mandatory real TS interop dependency missing: ' + dependency)
out = Path(os.environ['PAPERCUP_SEALED_NATIVE_OUT']).resolve()
out.mkdir(parents=True, exist_ok=False)
subprocess.run(['bash', 'tools/run-android-checks.sh', 'verify-emulator-boot', serial,
                str(out / 'preflight'), '1'], check=True)
fixture = Path('crates/papercup-core/tests/fixtures/sealed-http-responder.mjs').resolve()
child = None
reverse = None
result = {'serial': serial, 'scope': 'JNI Noise/HTTP/SSE and encrypted restore against real TS responder; VM fetch is injected, no live host or portal acceptance',
          'exitCode': 1, 'cleanupVerified': False, 'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
          'sourceDirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True)),
          'sourceFingerprints': {path: hashlib.sha256(Path(path).read_bytes()).hexdigest() for path in (
              'tools/run-android-checks.sh', 'crates/papercup-bindings/src/lib.rs',
              'android/app/src/main/kotlin/com/papercuspai/operator/mobile/Credentials.kt',
              'android/app/src/main/kotlin/com/papercuspai/operator/mobile/PairScreen.kt',
              'android/app/src/androidTest/kotlin/com/papercuspai/operator/mobile/SealedTransportInteropTest.kt', str(fixture))}}
try:
    with (out / 'responder.log').open('w') as log:
        child = subprocess.Popen(['node', '--import', 'tsx', str(fixture), str(operator), 'normal'],
                                 cwd=operator, stdout=subprocess.PIPE, stderr=log, text=True)
        if not select.select([child.stdout], [], [], 20)[0]:
            raise RuntimeError('TS responder readiness timed out')
        ready = json.loads(child.stdout.readline())
        (out / 'responder-ready.json').write_text(json.dumps(ready, indent=2) + '\n')
        url = urlparse(ready['base'])
        if url.hostname != '127.0.0.1' or not url.port:
            raise RuntimeError('TS responder must bind owned loopback')
        mapping = 'tcp:' + str(url.port)
        existing = subprocess.check_output(['adb', '-s', serial, 'reverse', '--list'], text=True)
        if any(mapping in row.split() for row in existing.splitlines()):
            raise RuntimeError('Refusing to replace a pre-existing emulator reverse mapping')
        subprocess.run(['adb', '-s', serial, 'reverse', mapping, mapping], check=True)
        reverse = mapping
        command = ['android/gradlew', '-p', 'android', ':app:connectedDebugAndroidTest', '--console=plain',
                   '-Pandroid.testInstrumentationRunnerArguments.sealedBase=' + ready['base'],
                   '-Pandroid.testInstrumentationRunnerArguments.sealedPin=' + base64.b64encode(bytes(ready['publicKey'])).decode()]
        selection = os.environ['PAPERCUP_SEALED_NATIVE_SELECTION']
        if selection == 'interop':
            command.append('-Pandroid.testInstrumentationRunnerArguments.class=com.papercuspai.operator.mobile.SealedTransportInteropTest')
        elif selection == 'all':
            command.append('--rerun-tasks')
        else:
            raise RuntimeError('sealed-native selection must be interop or all')
        reports = Path('android/app/build/outputs/androidTest-results/connected/debug')
        if reports.exists():
            shutil.rmtree(reports)
        with (out / 'gradle.log').open('w') as native_log:
            run = subprocess.run(command, stdout=native_log, stderr=subprocess.STDOUT, timeout=600)
        if reports.exists():
            shutil.copytree(reports, out / 'junit')
        if run.returncode:
            raise RuntimeError('Native sealed interop failed; see ' + str(out / 'gradle.log'))
        subprocess.run(['bash', 'tools/run-android-checks.sh', 'verify-results', 'android/app/build', 'connected'], check=True)
        import xml.etree.ElementTree as ET
        cases = [case for report in (out / 'junit').rglob('TEST-*.xml') for case in ET.parse(report).iter('testcase')
                 if case.get('classname') == 'com.papercuspai.operator.mobile.SealedTransportInteropTest']
        if len(cases) != 2:
            raise RuntimeError('Both maintained native sealed interop cases must execute')
        result.update(exitCode=0, tests=[case.get('name') for case in cases])
        result['apkSha256'] = hashlib.sha256(Path('android/app/build/outputs/apk/debug/app-debug.apk').read_bytes()).hexdigest()
finally:
    if reverse:
        subprocess.run(['adb', '-s', serial, 'reverse', '--remove', reverse], check=True)
    if child:
        child.terminate()
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            child.kill(); child.wait(timeout=10)
    result['cleanupVerified'] = True
    (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
PY
    exit
fi
if [[ "$mode" == verify-rust-toolchain ]]; then
    resolve_rust_toolchain
    exit
fi
if [[ "$mode" == verify-native-dependencies ]]; then
    # Fail before another expensive API36 run with Espresso's removed reflective
    # InputManager API. AndroidX 3.7.0 uses the public system service instead.
    python3 - "${2:-android/app/build.gradle.kts}" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
versions = re.findall(r'androidTestImplementation\("androidx\.test\.espresso:espresso-intents:([^"\n]+)"\)', text)
if (len(versions) != 1 or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', versions[0])
        or tuple(map(int, versions[0].split('.'))) < (3, 7, 0)):
    raise SystemExit('API36 native tests require a stable Espresso intents version >=3.7.0')
print('API36 Espresso dependency precondition passed: ' + versions[0])
PY
    exit
fi
if [[ "$mode" == verify-isolated-native ]]; then
    python3 - "${2:?paired evidence directory required}" "${3:?exact operator source SHA required}" <<'PY'
import hashlib
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

out, expected = Path(sys.argv[1]), sys.argv[2]
if not re.fullmatch('[0-9a-f]{40}', expected):
    raise SystemExit('Exact operator commit required')
native = json.loads((out / 'result.json').read_text())
runtime = json.loads((Path(str(out) + '-runtime') / 'result.json').read_text())
if (native.get('checkKind') != 'native' or native.get('exitCode') != 0
        or not all(native.get(k) is True for k in ('executionStarted', 'cleanupVerified'))
        or runtime.get('exitCode') != 0
        or not all(runtime.get(k) is True for k in ('executionStarted', 'hostCleanupVerified', 'nativeProcessCleanupVerified'))
        or runtime.get('operatorSourceCommit') != expected
        or not re.fullmatch('[0-9a-f]{7,40}', runtime.get('health', {}).get('sha') or '')
        or not expected.startswith(runtime.get('health', {}).get('sha') or '!')
        or not re.fullmatch('[0-9a-f]{64}', runtime.get('bundleSha256', ''))
        or native.get('runtime') != runtime.get('runtime')
        or not runtime.get('workspaceId', '').startswith('test-runtime-')):
    raise SystemExit('Paired proof lacks successful isolated execution, cleanup or exact counterpart')
journey = native.get('nativeJourney', {})
required = ('journeyCompleted', 'authenticatedRequestPassed', 'returnedToPairedShell',
            'activityRecreated', 'valueRowLabelsPassed', 'enrollmentBrowserStubbed',
            'inboxScopedReadPassed', 'inboxRenderingPassed', 'inboxUnauthorizedPassed',
            'inboxRecoveryPassed', 'navigationPassed', 'credentialsCleared',
            'expiredJwtControlPassed', 'expiredJwtRejected', 'expiredJwtRenderingPassed',
            'expiredJwtFreshPairPassed', 'revokedDeviceRejected',
            'revokedDeviceRenderingPassed', 'revokedDeviceFreshPairPassed',
            'revocationMissingPromptBlocked', 'revocationDeniedPromptBlocked',
            'revocationApprovedPromptInvoked', 'revocationBiometricPromptStubbed')
features = native.get('nativeSelection') == 'features'
if features:
    required = ('journeyCompleted', 'authenticatedRequestPassed', 'returnedToPairedShell',
        'activityRecreated', 'enrollmentBrowserStubbed', 'credentialsCleared',
        'chatStatePassed', 'plansStatePassed', 'attentionApprovalsStatePassed',
        'fleetStatePassed', 'workspacePotStatePassed', 'diagnosticsStatePassed')
    # Pass flags alone cannot establish what the JNI oracle measured. Keep
    # the observed population and workspace binding mandatory, including
    # honest zero populations (which do not imply populated acceptance).
    state = journey.get('featureExpectedState')
    if (not isinstance(state, dict)
            or any(type(state.get(key)) is not int or state[key] < 0
                   for key in ('chatTurns', 'plans', 'pots', 'standingCandidates'))
            or state.get('workspaceId') != native.get('ownedWorkspace', {}).get('id')
            or not isinstance(state.get('workspaceName'), str) or not state['workspaceName'].strip()
            or not isinstance(state.get('fleetAvailability'), str) or not state['fleetAvailability'].strip()):
        raise SystemExit('Feature JNI expected-state witness is missing, malformed or foreign-scoped')
if (journey.get('runId') != native.get('runId')
        or journey.get('workspaceId') != native.get('ownedWorkspace', {}).get('id')
        or not journey.get('deviceId') in native.get('ownedDeviceIds', [])
        or journey.get('currentStage') != 'completed'
        or not all(journey.get(k) is True for k in required)):
    raise SystemExit('Paired journey is missing, incomplete or belongs to another attempt')
fingerprints = native.get('sourceFingerprints', {})
if not fingerprints or 'tools/run-android-checks.sh' not in fingerprints:
    raise SystemExit('Native source fingerprints required')
for path, digest in fingerprints.items():
    if hashlib.sha256(Path(path).read_bytes()).hexdigest() != digest:
        raise SystemExit('Paired source is stale: ' + path)
artifacts = {Path(a['path']).name: a['sha256'] for a in native.get('artifacts', [])}
for name in ('app-debug.apk', 'app-debug-androidTest.apk'):
    if hashlib.sha256((out / name).read_bytes()).hexdigest() != artifacts.get(name):
        raise SystemExit('Missing or changed tested APK: ' + name)
reports = list((out / 'native-results').rglob('TEST-*.xml'))
cases = [case for report in reports for case in ET.parse(report).getroot().iter('testcase')]
required_cases = {'launcherActivityStarts', 'privateInboxScopeAcceptsOnlyDocumentedGlobalControls',
         'unauthorizedSendKeepsDraftWithoutInventingAPersistedTurn',
         'forbiddenSendKeepsDraftWithoutInventingAPersistedTurn',
         'rejectedDraftSurvivesSettingsRoundTrip',
         'rejectedDraftSurvivesSameScopeRepairAndActivityRecreation',
         'repairToAnotherWorkspaceDoesNotExposePreviousDraft',
         'repairToAnotherServerDoesNotExposePreviousDraft'}
if features:
    required_cases = {'sixFeatureJourneysMatchOwnedOperatorState'}
if (len(cases) != len(required_cases) or {c.get('name') for c in cases} != required_cases
        or any(c.find(tag) is not None for c in cases for tag in ('failure', 'error', 'skipped'))
        or any(int(suite.get(tag, '0')) for report in reports
               for suite in ET.parse(report).getroot().iter('testsuite')
               for tag in ('failures', 'errors', 'skipped'))):
    raise SystemExit('Exact successful selected native tests required')
print('Isolated paired native proof: source/counterpart/APK/JUnit/journey/cleanup verified')
PY
    exit $?
fi
if [[ "$mode" == isolated-native ]]; then
    export PAPERCUP_ANDROID_NATIVE_SELECTION="${4:-historical}"
    [[ "$PAPERCUP_ANDROID_NATIVE_SELECTION" == historical || "$PAPERCUP_ANDROID_NATIVE_SELECTION" == features ]] || {
        echo 'Native selection must be historical or features' >&2; exit 2;
    }
    # Resolve and pin under the same lock used by staging generation GC. An
    # exported variable is not visible in /proc/environ until exec, so retain
    # the shared lock through re-exec; the new process then owns the reference.
    exec 9>/tmp/papercup-staging-sync.lock
    flock -s 9
    operator_root="$(realpath -e "${2:?isolated-native requires the operator checkout}")"
    exec env PAPERCUSP_INTEGRATION_ROOT="$operator_root" \
        bash "$ROOT/tools/run-android-checks.sh" isolated-native-pinned "$operator_root" "${3:-}"
fi
if [[ "$mode" == isolated-native-pinned ]]; then
    operator_root="$(realpath -e "${2:?isolated-native requires the operator checkout}")"
    [[ "${PAPERCUSP_INTEGRATION_ROOT:-}" == "$operator_root" && -e /proc/$$/fd/9 ]] || {
        echo 'isolated-native requires an inherited staging lock and process reference' >&2
        exit 2
    }
    # The initial process environment now pins this generation for GC. Do not
    # hold the global sync lock during fixtures, builds or instrumentation.
    exec 9>&-
    resolve_rust_toolchain
    # Reuse the operator's migrated-PG/profile owner; never reproduce its
    # isolation setup here or connect this journey to the shared operator.
    [[ -f "$operator_root/scripts/with-test-pg.mjs" &&
       -f "$operator_root/apps/operator/dist-host/hono-host.mjs" ]] || {
        echo 'isolated-native requires a prepared operator checkout and host bundle' >&2
        exit 2
    }
    node "$operator_root/apps/operator/bin/bundle-host-freshness.mjs" check \
        --repo-root "$operator_root" --entry "$operator_root/apps/operator/bin/hono-host.ts" \
        --outfile "$operator_root/apps/operator/dist-host/hono-host.mjs" \
        --manifest "$operator_root/apps/operator/dist-host/.bundle-fresh.json"
    # Catch fixture contract and high-risk approval regressions before the
    # expensive native leg. These are controls, not native acceptance.
    bash tools/tests/run-android-checks-test.sh
    cargo test -p papercup-core --lib biometric::tests -- --nocapture
    export PAPERCUP_ANDROID_RUNNER="$ROOT/tools/run-android-checks.sh"
    export PAPERCUP_OPERATOR_ROOT="$operator_root"
    PAPERCUP_ANDROID_EVIDENCE="$(realpath -m "${3:-android/app/build/ci-evidence/isolated-native-$(date -u +%Y%m%dT%H%M%SZ)}")"
    export PAPERCUP_ANDROID_EVIDENCE
    # The runtime's private HOME must not hide the explicitly selected build
    # toolchain. These paths contain toolchain state, not operator identity.
    export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
    export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/27.0.12077973}"
    if [[ -z "${JAVA_HOME:-}" ]]; then
        JAVA_HOME="$(bash tools/build-scripts/resolve-java-home.sh)"
        export JAVA_HOME
    fi
    exec node "$operator_root/scripts/with-test-pg.mjs" --isolated-runtime=operator-api \
        -- bash "$PAPERCUP_ANDROID_RUNNER" isolated-native-child
fi

if [[ "$mode" == isolated-native-child ]]; then
    python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import signal
import secrets
import subprocess
import time
import urllib.request

required = {'PAPERCUSP_BACKGROUND_WORKERS': '0', 'PAPERCUSP_DBOS_ENABLE': '0',
            'PAPERCUSP_CLUSTER': '0', 'PAPERCUSP_SKIP_PG_DISCOVERY': '1',
            'PAPERCUSP_BIND_HOST': '127.0.0.1'}
if any(os.environ.get(k) != v for k, v in required.items()):
    raise SystemExit('isolated-native-child requires the canonical operator-api isolation profile')
workspace = os.environ.get('PAPERCUSP_WORKSPACE_ID', '')
home = Path(os.environ.get('HOME', '/'))
if not workspace.startswith('test-runtime-') or not home.parent.name.startswith('papercusp-test-runtime-'):
    raise SystemExit('isolated-native-child refuses an ambient workspace or HOME')
base = os.environ.get('PAPERCUSP_OPERATOR_URL', '')
if base != 'http://127.0.0.1:' + os.environ.get('PAPERCUSP_HONO_PORT', ''):
    raise SystemExit('isolated-native-child requires its owned loopback operator port')
# Share one private, in-memory signing secret with the owned host and fixture
# signer. Never read a production secret or persist this test-only credential.
os.environ['MOBILE_JWT_SECRET'] = secrets.token_urlsafe(48)
os.environ['PAPERCUP_ANDROID_AUTH_FIXTURE'] = '0' if os.environ.get('PAPERCUP_ANDROID_NATIVE_SELECTION') == 'features' else '1'
operator = Path(os.environ['PAPERCUP_OPERATOR_ROOT'])
bundle = operator / 'apps/operator/dist-host/hono-host.mjs'
evidence = Path(os.environ['PAPERCUP_ANDROID_EVIDENCE'])
if evidence.exists():
    raise SystemExit('isolated-native refuses existing native evidence')
runtime_evidence = Path(str(evidence) + '-runtime')
runtime_evidence.mkdir(mode=0o700, parents=True, exist_ok=False)
source = subprocess.run(['git', '-C', str(operator), 'rev-parse', 'HEAD'],
                        capture_output=True, text=True)
proof = {'schemaVersion': 1, 'runtime': base, 'workspaceId': workspace,
         'operatorSourceCommit': source.stdout.strip() if source.returncode == 0 else None,
         'bundleSha256': hashlib.sha256(bundle.read_bytes()).hexdigest(),
         'profile': 'with-test-pg --isolated-runtime=operator-api',
         'backgroundDisabled': True, 'dbosDisabled': True,
         'executionStarted': False, 'exitCode': 1, 'hostCleanupVerified': False,
         'scope': 'Private operator/debug native integration; not signed-candidate, physical-phone or Play acceptance'}
host = None
native = None
def interrupted(signum, frame):
    raise RuntimeError('private native runtime interrupted')
signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
try:
    with (runtime_evidence / 'host.log').open('w') as log:
        host = subprocess.Popen(['node', str(bundle)], cwd=operator,
                                stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        proof['hostPid'] = host.pid
        deadline = time.monotonic() + 60
        while True:
            if host.poll() is not None:
                raise RuntimeError('private operator exited before readiness')
            try:
                with urllib.request.urlopen(base + '/api/health', timeout=2) as response:
                    health = json.load(response)
                with urllib.request.urlopen(base + '/api/workspaces', timeout=2) as response:
                    registry = json.load(response)
                if (health.get('ok') is True and health.get('service') == 'papercusp-operator'
                        and registry.get('current') == workspace
                        and {r['id'] for r in registry['workspaces']} == {workspace}):
                    proof['health'] = health
                    expected = os.environ.get('PAPERCUP_OPERATOR_SHA')
                    if expected and (proof['operatorSourceCommit'] != expected
                            or not isinstance(health.get('sha'), str)
                            or len(health['sha']) < 7 or not expected.startswith(health['sha'])):
                        raise RuntimeError('private operator loaded source differs from the pinned counterpart')
                    break
            except (OSError, ValueError):
                pass
            if time.monotonic() >= deadline:
                raise RuntimeError('private operator health/workspace readiness timed out')
            time.sleep(0.25)
        env = dict(os.environ, PAPERCUP_LIVE_BASE=base)
        proof['executionStarted'] = True
        native = subprocess.Popen(['bash', os.environ['PAPERCUP_ANDROID_RUNNER'], 'live',
                                   str(evidence), 'native'], env=env, start_new_session=True)
        # The native child owns its own build budget (PAPERCUP_NATIVE_BUILD_TIMEOUT_SEC);
        # wait for that plus the original 1800s test allowance, never less.
        native_build_budget = int(os.environ.get('PAPERCUP_NATIVE_BUILD_TIMEOUT_SEC', '2400'))
        proof['exitCode'] = native.wait(timeout=1800 + native_build_budget)
except Exception as error:
    proof['error'] = str(error)
finally:
    if native is not None:
        try:
            os.killpg(native.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            native.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(native.pid, signal.SIGKILL)
            native.wait(timeout=10)
        proof['nativeProcessCleanupVerified'] = native.poll() is not None
    if host is not None:
        if host.poll() is None:
            os.killpg(host.pid, signal.SIGTERM)
            try:
                host.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(host.pid, signal.SIGKILL)
                host.wait(timeout=10)
        proof['hostCleanupVerified'] = host.poll() is not None
    (runtime_evidence / 'result.json').write_text(json.dumps(proof, indent=2) + '\n')
raise SystemExit(proof['exitCode'] if proof['hostCleanupVerified'] else 1)
PY
    exit $?
fi

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
# The native four-ABI Rust + Gradle build is not a live-smoke step: a cold
# Cargo cache (for example right after a toolchain target is added) compiles
# every dependency for four ABIs and cannot fit the live budget. Give it its own.
build_timeout = int(os.environ.get('PAPERCUP_NATIVE_BUILD_TIMEOUT_SEC', '2400'))
if not 60 <= build_timeout <= 7200:
    raise SystemExit('native build timeout must be between 60 and 7200 seconds')
attempt = uuid.uuid4().hex
out = Path(sys.argv[1] or f'android/app/build/ci-evidence/live-{attempt}')
out.mkdir(parents=True, exist_ok=False, mode=0o700)
log_path = out / ('native-test.log' if kind == 'native' else 'cargo-test.log')

def api(path, method='GET', body=None, bearer=None, workspace_id=None):
    headers = {'Content-Type': 'application/json'}
    if workspace_id is not None:
        headers['x-papercusp-workspace'] = workspace_id
    if bearer is not None:
        headers['Authorization'] = 'Bearer ' + bearer
    request = urllib.request.Request(base + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)

def seed_feature_chat(workspace_id, run_id):
    # Only called by the private isolated feature profile, after ownership is
    # established. Explicit request scope keeps the host's home thread empty.
    for role in ('user', 'assistant'):
        text = f'owned {role} {run_id}'
        saved = api('/api/operator/conversations/active/turns', 'POST',
                    {'role': role, 'text': text, 'source': 'text_typed'},
                    workspace_id=workspace_id)
        turn = saved.get('turn', {})
        if turn.get('role') != role or turn.get('text') != text or not saved.get('conversationId'):
            raise RuntimeError('private chat fixture did not persist the expected turn')

def verify_feature_chat(workspace_id, run_id):
    # Validate the same authenticated endpoint JNI will read. A successful
    # desktop write alone cannot prove that the device sees its paired scope.
    minted = api('/api/device/desktop/mint-pair-token', 'POST', {'workspaceId': workspace_id})
    native_pair_tokens.append(minted)
    control = api('/api/device/pair', 'POST', {'pairToken': minted['qrPayload']['pairToken']})
    device_id = control.get('deviceId', '')
    if (control.get('workspaceId') != workspace_id or device_id in existing_devices
            or not re.fullmatch('[0-9a-f-]{36}', device_id)):
        raise RuntimeError('chat readback control did not return an owned newly paired device')
    result['ownedDeviceIds'].append(device_id)
    try:
        read = api('/api/device/operator/conversation?limit=50', bearer=control['deviceToken'])
        turns = read.get('turns', [])
        expected = {('user', f'owned user {run_id}'), ('assistant', f'owned assistant {run_id}')}
        observed = {(turn.get('role'), turn.get('text')) for turn in turns}
        if (read.get('conversation', {}).get('workspaceId') != workspace_id
                or len(turns) != 2 or observed != expected):
            raise RuntimeError('owned device chat readback did not match the populated private fixture')
        result['featureChatFixtureBasis'] = {
            'workspaceId': workspace_id, 'deviceReadbackPassed': True, 'turnCount': len(turns),
        }
    finally:
        api('/api/device/desktop/devices/' + device_id, 'DELETE')

def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

before = None
workspace = None
existing = set()
setup_ready = False
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
          'log': str(log_path), 'exitCode': 1, 'executionStarted': False, 'cleanupVerified': False}
fixture_id = None
token = None
native_pair_tokens = []
auth_fixture_enabled = kind == 'native' and os.environ.get('PAPERCUP_ANDROID_AUTH_FIXTURE') == '1'
feature_fixture_enabled = kind == 'native' and os.environ.get('PAPERCUP_ANDROID_NATIVE_SELECTION') == 'features'
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
    subprocess.run(['bash', str(Path('tools/run-android-checks.sh').resolve()),
                    'verify-native-dependencies'], check=True, timeout=15)
    if auth_fixture_enabled and (len(os.environ.get('MOBILE_JWT_SECRET', '')) < 32
            or not (Path(os.environ.get('PAPERCUP_OPERATOR_ROOT', '')) /
                    'packages/operator-core/lib/device-jwt.ts').is_file()):
        raise RuntimeError('native auth fixture requires its owned operator signer and injected private secret')
    devices = subprocess.check_output(['adb', 'devices'], text=True)
    serials = [line.split()[0] for line in devices.splitlines()[1:]
               if len(line.split()) == 2 and line.split()[1] == 'device']
    requested = os.environ.get('ANDROID_SERIAL')
    if (not requested or not requested.startswith('emulator-')
            or serials.count(requested) != 1):
        raise RuntimeError('native live checks require an online explicitly owned emulator')
    # Peer transports may share the host ADB server. Every subsequent command
    # targets this explicit serial; never infer ownership from list order.
    native_device = requested
    for args, expected in [(('shell', 'getprop', 'sys.boot_completed'), '1'),
                           (('shell', 'getprop', 'ro.build.version.sdk'), '36'),
                           (('shell', 'getconf', 'PAGE_SIZE'), '16384')]:
        if adb(*args).stdout.strip() != expected:
            raise RuntimeError('native live emulator must be booted API36 with 16KB pages')
    subprocess.run(['bash', str(Path('tools/run-android-checks.sh').resolve()), 'verify-emulator-boot',
                    native_device, str(out / 'emulator-preflight'), '1'],
                   check=True, timeout=45)
    env = os.environ.copy()
    if not env.get('JAVA_HOME'):
        env['JAVA_HOME'] = subprocess.check_output(
            ['bash', 'tools/build-scripts/resolve-java-home.sh'], text=True).strip()
    with log_path.open('w') as log:
        # Reuse the four-ABI/JNI/checksum/alignment build; a Gradle-only
        # rebuild could otherwise execute a stale Rust shared library.
        subprocess.run(['bash', 'tools/build-scripts/build-android.sh', 'debug'],
                       env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=build_timeout)
        subprocess.run(['android/gradlew', '-p', 'android',
                        ':app:assembleDebugAndroidTest', '--console=plain'],
                       env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=build_timeout)
    apk = 'android/app/build/outputs/apk/debug/app-debug.apk'
    installed = adb('install', '-r', apk, check=False)
    if (installed.returncode != 0 and 'INSTALL_FAILED_UPDATE_INCOMPATIBLE'
            in installed.stdout + installed.stderr):
        # A differently-signed build holds the package on this owned
        # emulator; its private data is not this build's state, and -r can
        # never replace it. Remove both packages, then install once more.
        for package in (app + '.test', app):
            adb('uninstall', package, check=False)
        result['replacedIncompatiblePackage'] = True
        installed = adb('install', '-r', apk, check=False)
    if installed.returncode != 0:
        raise RuntimeError('adb install failed: '
                           + (installed.stdout + installed.stderr).strip()[-500:])
    app_shell('test ! -e files/native-pairing-fixture.json && test ! -e files/native-pairing-result.json && test ! -e files/native-pairing-failure.png')
    app_shell('mkdir -p files')

def native_auth_fixture(port):
    def mint():
        minted = api('/api/device/desktop/mint-pair-token', 'POST', {'workspaceId': fixture_id})
        native_pair_tokens.append(minted)
        return minted

    control = api('/api/device/pair', 'POST', {'pairToken': mint()['qrPayload']['pairToken']})
    if (control.get('workspaceId') != fixture_id or control.get('deviceId') in existing_devices
            or not re.fullmatch('[0-9a-f-]{36}', control.get('deviceId', ''))):
        raise RuntimeError('expiry control did not return an owned newly paired device')
    result['ownedDeviceIds'].append(control['deviceId'])
    # The positive control reaches the same actual endpoint before expiry.
    result['authFixtureStage'] = 'positive-control'
    api('/api/device/attention', bearer=control['deviceToken'])
    result['authFixtureBasis'] = {'controlDeviceId': control['deviceId'], 'controlAccepted': True}
    result['authFixtureStage'] = 'sign-expired-control'
    operator = Path(os.environ['PAPERCUP_OPERATOR_ROOT'])
    signer = operator / 'packages/operator-core/lib/device-jwt.ts'
    script = '''
import {readFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
import {resolve} from 'node:path';
const {signDeviceToken, verifyDeviceToken} = await import(pathToFileURL(resolve('packages/operator-core/lib/device-jwt.ts')).href);
const input = JSON.parse(readFileSync(0, 'utf8'));
const claims = verifyDeviceToken(input.controlToken);
if (!claims || claims.sub !== input.deviceId || claims.workspace_id !== input.workspaceId) throw Error('Control signature/scope mismatch');
const realNow = Date.now;
Date.now = () => realNow() - 366 * 24 * 3600 * 1000;
let expired;
try { expired = signDeviceToken({sub: claims.sub, workspace_id: claims.workspace_id, device_kind: 'mobile', user_email: claims.user_email}); }
finally { Date.now = realNow; }
if (verifyDeviceToken(expired) !== null) throw Error('Expiry control did not expire');
process.stdout.write(expired);
'''
    signed = subprocess.run(['node', '--import', 'tsx', '--input-type=module', '-e', script],
        cwd=operator, input=json.dumps({'controlToken': control['deviceToken'],
            'deviceId': control['deviceId'], 'workspaceId': fixture_id}),
        capture_output=True, text=True, check=True, timeout=30)
    expired = signed.stdout.strip()
    if len(expired.split('.')) != 3:
        raise RuntimeError('owned signer did not return an expired JWT')
    result['authFixtureStage'] = 'expired-rejection'
    try:
        api('/api/device/attention', bearer=expired)
    except HTTPError as error:
        if error.code not in (401, 403):
            raise
        rejected_status = error.code
    else:
        raise RuntimeError('actual expired JWT was accepted by the owned operator')
    result['authFixtureBasis'] = {'controlDeviceId': control['deviceId'],
        'controlAccepted': True, 'expiredRejectedStatus': rejected_status,
        'expiredTokenSha256': hashlib.sha256(expired.encode()).hexdigest(),
        'signerSourceSha256': hashlib.sha256(signer.read_bytes()).hexdigest(),
        'method': 'existing signDeviceToken with past clock; same signature/scope/device positive control'}
    result['authFixtureStage'] = 'fresh-repair-tokens'
    def payload(minted):
        return dict(minted['qrPayload'], server=f'http://127.0.0.1:{port}', workspaceId=fixture_id)
    return {'controlDeviceId': control['deviceId'], 'controlToken': control['deviceToken'],
        'expiredToken': expired, 'expiredRepairPayload': payload(mint()),
        'revokedRepairPayload': payload(mint())}

try:
    # Initialize the result before any fallible service prerequisite. A
    # disconnected or invalid workspace API must leave an honest failure
    # record even though no command or owned fixture was started.
    before = api('/api/workspaces')
    workspace = os.environ.get('PAPERCUP_LIVE_WORKSPACE', before.get('current'))
    existing = {row['id'] for row in before['workspaces']}
    if not before.get('current') or workspace not in existing:
        raise RuntimeError('live checks require an existing workspace and current selection')
    setup_ready = True
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
    if feature_fixture_enabled:
        seed_feature_chat(fixture_id, attempt)
        verify_feature_chat(fixture_id, attempt)
    token = api('/api/device/desktop/mint-pair-token', 'POST',
                {'workspaceId': fixture_id if kind == 'native' else workspace})
    if kind == 'native':
        native_pair_tokens.append(token)
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
        fixture_payload = {'schemaVersion': 1, 'runId': attempt,
                           'workspaceId': fixture_id, 'pairPayload': payload}
        if auth_fixture_enabled:
            fixture_payload['auth'] = native_auth_fixture(port)
        app_shell('umask 077; set -C; cat > files/native-pairing-fixture.json',
            input=json.dumps(fixture_payload))
        native_payload_created = True
        shutil.rmtree(connected, ignore_errors=True)
        command = ['android/gradlew', '-p', 'android', ':app:connectedDebugAndroidTest',
                   '--rerun', '--console=plain',
                   '-Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true',
                   '-Pandroid.testInstrumentationRunnerArguments.class=com.papercuspai.operator.mobile.PapercupAppSmokeTest#launcherActivityStarts,com.papercuspai.operator.mobile.PapercupAppSmokeTest#privateInboxScopeAcceptsOnlyDocumentedGlobalControls,com.papercuspai.operator.mobile.OperatorChatScreenTest',
                   '-Pandroid.testInstrumentationRunnerArguments.nativePairingFixture=true']
        if auth_fixture_enabled:
            command.append('-Pandroid.testInstrumentationRunnerArguments.nativeAuthFixture=true')
        if feature_fixture_enabled:
            command = [arg for arg in command if not arg.startswith('-Pandroid.testInstrumentationRunnerArguments.class=')]
            command += ['-Pandroid.testInstrumentationRunnerArguments.class=com.papercuspai.operator.mobile.PapercupAppSmokeTest#sixFeatureJourneysMatchOwnedOperatorState',
                        '-Pandroid.testInstrumentationRunnerArguments.nativeFeatureFixture=true']
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
                            'android/app/src/androidTest/kotlin/com/papercuspai/operator/mobile/UniffiCallbackTest.kt']})
    with log_path.open('a' if kind == 'native' else 'w') as log:
        result['executionStarted'] = True
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
        required_native_tests = {'launcherActivityStarts', 'privateInboxScopeAcceptsOnlyDocumentedGlobalControls',
                                 'unauthorizedSendKeepsDraftWithoutInventingAPersistedTurn',
                                 'forbiddenSendKeepsDraftWithoutInventingAPersistedTurn',
                                 'rejectedDraftSurvivesSettingsRoundTrip',
                                 'rejectedDraftSurvivesSameScopeRepairAndActivityRecreation',
                                 'repairToAnotherWorkspaceDoesNotExposePreviousDraft',
                                 'repairToAnotherServerDoesNotExposePreviousDraft'}
        if feature_fixture_enabled:
            required_native_tests = {'sixFeatureJourneysMatchOwnedOperatorState'}
        if (len(cases) != len(required_native_tests)
                or {case.get('name') for case in cases} != required_native_tests
                or any(case.find(tag) is not None for case in cases for tag in ('failure', 'error', 'skipped'))
                or any(int(suite.get(tag, '0')) for file in reports
                       for suite in ET.parse(file).getroot().iter('testsuite')
                       for tag in ('failures', 'errors', 'skipped'))):
            raise RuntimeError('native journey and scope controls must each execute exactly once without failures or skips')
        proof = json.loads(app_shell('cat files/native-pairing-result.json').stdout)
        required_journey = ('journeyCompleted', 'authenticatedRequestPassed', 'returnedToPairedShell',
                     'activityRecreated', 'valueRowLabelsPassed', 'enrollmentBrowserStubbed',
                     'inboxScopedReadPassed', 'inboxRenderingPassed',
                     'inboxUnauthorizedPassed', 'inboxRecoveryPassed',
                     'navigationPassed', 'credentialsCleared')
        if feature_fixture_enabled:
            required_journey = ('journeyCompleted', 'authenticatedRequestPassed', 'returnedToPairedShell',
                'activityRecreated', 'enrollmentBrowserStubbed', 'credentialsCleared',
                'chatStatePassed', 'plansStatePassed', 'attentionApprovalsStatePassed',
                'fleetStatePassed', 'workspacePotStatePassed', 'diagnosticsStatePassed')
            result['nativeSelection'] = 'features'
        if (proof.get('runId') != attempt or proof.get('workspaceId') != fixture_id
                or proof.get('currentStage') != 'completed'
                or not all(proof.get(k) is True for k in required_journey)):
            raise RuntimeError('native live journey proof is missing, mismatched or incomplete')
        if auth_fixture_enabled and not all(proof.get(k) is True for k in
                ('expiredJwtControlPassed', 'expiredJwtRejected', 'expiredJwtRenderingPassed',
                 'expiredJwtFreshPairPassed', 'revokedDeviceRejected',
                 'revokedDeviceRenderingPassed', 'revokedDeviceFreshPairPassed',
                 'revocationMissingPromptBlocked', 'revocationDeniedPromptBlocked',
                 'revocationApprovedPromptInvoked', 'revocationBiometricPromptStubbed')):
            raise RuntimeError('actual expiry/revocation and fresh-pair recovery proof required')
        registered = api('/api/device/desktop/devices')['devices']
        if (proof.get('deviceId') in existing_devices or not any(
                row['device_id'] == proof.get('deviceId') and row.get('workspace_id') == fixture_id
                for row in registered)):
            raise RuntimeError('native proof must name a newly paired device in the owned workspace')
        result['nativeJourney'] = proof
        for device in proof.get('pairedDeviceIds', []):
            if not re.fullmatch('[0-9a-f-]{36}', device) or device in existing_devices:
                raise RuntimeError('native auth proof names an unowned device')
            if device not in result['ownedDeviceIds']:
                result['ownedDeviceIds'].append(device)
    if kind == 'rust' and result['exitCode'] == 0 and not re.search(
            r'test result: ok\. 1 passed; 0 failed; 0 ignored;', text):
        result['exitCode'] = 1
        errors.append('canonical live test did not execute exactly once without failures or skips')
except Exception as error:
    if not setup_ready:
        result['setupFailed'] = True
        result['setupFailureClass'] = error.__class__.__name__
    errors.append(str(error))
    result['exitCode'] = result['exitCode'] or 1
finally:
    if native_execution_started:
        try:
            diagnostics = adb('logcat', '-d', '-v', 'epoch', '-s', 'PapercupPairing:I', '*:S').stdout
            trace = out / 'pairing-stages.log'
            trace.write_text(diagnostics)
            trace.chmod(0o600)
            stages = re.findall(r'\bstage=([a-z-]+)', diagnostics)
            result['pairingDiagnostics'] = {'path': str(trace), 'stages': stages,
                'sha256': hashlib.sha256(trace.read_bytes()).hexdigest()}
            if result['exitCode'] == 0 and not all(stage in stages for stage in
                    ['client-start', 'client-ready', 'request-start', 'response-received', 'credentials-saved']):
                result['exitCode'] = 1
                errors.append('successful native journey lacks pairing-stage diagnostics')
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
            for pending_token in native_pair_tokens:
                try:
                    burned = api('/api/device/pair', 'POST', {'pairToken': pending_token['qrPayload']['pairToken']})
                    result['nativePairTokenDisposition'] = 'redeemed-by-cleanup'
                    if burned.get('deviceId') and burned['deviceId'] not in existing_devices:
                        result['ownedDeviceIds'].append(burned['deviceId'])
                except HTTPError as error:
                    if error.code != 401 or json.load(error).get('error') != 'invalid_or_expired_token':
                        raise
                    result['nativePairTokenDisposition'] = 'redeemed-before-cleanup'
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
        if setup_ready:
            after = api('/api/workspaces')
            if (after.get('current') != before['current'] or
                    fixture_id and any(row['id'] == fixture_id for row in after['workspaces'])):
                raise RuntimeError('workspace cleanup or current-selection preservation failed')
        else:
            result['cleanupScope'] = 'No remote or native fixtures were allocated'
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
if [[ "$mode" == verify-emulator-boot ]]; then
    serial="${2:?explicit owned emulator serial is required}"
    attempt_dir="${3:?boot evidence directory is required}"
    checks="${4:-120}"
    [[ "$serial" =~ ^emulator-[0-9]+$ && "$checks" =~ ^[1-9][0-9]*$ ]] || exit 2
    mkdir -p "$attempt_dir"
    boot_ready=0
    for ((n=1; n<=checks; n++)); do
        adb -s "$serial" shell getprop sys.boot_completed > "$attempt_dir/boot-property.txt" 2> "$attempt_dir/boot-adb-error.txt" || true
        if [[ "$(tr -d '\r\n' < "$attempt_dir/boot-property.txt")" == 1 ]]; then boot_ready=1; break; fi
        if (( n < checks )); then sleep 1; fi
    done
    adb devices -l > "$attempt_dir/boot-transports.txt" 2>&1 || true
    python3 - "$serial" "$attempt_dir" "$boot_ready" "$n" <<'PY'
import json, re, subprocess, sys, time
from pathlib import Path
serial, destination, ready, count = sys.argv[1:]
out = Path(destination)
proof = {'serial': serial, 'bootCompleted': ready == '1', 'checks': int(count),
         'property': (out / 'boot-property.txt').read_text().strip(),
         'adbError': (out / 'boot-adb-error.txt').read_text().strip(),
         'transportEvidence': 'boot-transports.txt'}
proof['frameworkReady'] = False
proof['frameworkSamples'] = []
proof['frameworkErrors'] = []
def adb(*args):
    result = subprocess.run(['adb', '-s', serial, *args], capture_output=True,
                            text=True, timeout=8)
    if result.returncode:
        raise RuntimeError(f'{args}: exit {result.returncode}: {result.stdout}{result.stderr}')
    return result.stdout.strip()

if proof['bootCompleted']:
    try:
        memory = adb('shell', 'cat', '/proc/meminfo')
        (out / 'guest-memory.txt').write_text(memory + '\n')
        values = {}
        for name in ('MemTotal', 'MemAvailable'):
            matches = re.findall(r'^' + name + r':\s+([0-9]+) kB\s*$', memory, re.MULTILINE)
            if len(matches) != 1:
                raise RuntimeError('Native guest memory is unmeasured: ' + name)
            values[name] = int(matches[0])
        # A 1536-MiB guest booted but LMK killed instrumentation before any test.
        # Allow kernel reservations in a 4096-MiB guest; also measure current
        # headroom so a healthy boot flag cannot admit an exhausted guest.
        proof['guestMemory'] = {'totalKiB': values['MemTotal'],
                                'availableKiB': values['MemAvailable'],
                                'requiredTotalKiB': 3584 * 1024,
                                'requiredAvailableKiB': 1536 * 1024}
        proof['guestMemory']['sufficient'] = (values['MemTotal'] >= 3584 * 1024
                                             and values['MemAvailable'] >= 1536 * 1024)
        if not proof['guestMemory']['sufficient']:
            raise RuntimeError('Insufficient native guest memory; allocate at least 4096 MiB '
                               'and provide 1536 MiB available before instrumentation')
        for index in range(3):
            sample = {name: adb('shell', 'pidof', name)
                      for name in ('surfaceflinger', 'system_server')}
            sample['settings'] = adb('shell', 'settings', 'get', 'global', 'airplane_mode_on')
            if sample['settings'] not in ('0', '1'):
                raise RuntimeError('Native settings service did not return a valid value')
            if any(not re.fullmatch(r'[1-9][0-9]*', sample[name])
                   for name in ('surfaceflinger', 'system_server')):
                raise RuntimeError('Native framework process is missing')
            proof['frameworkSamples'].append(sample)
            if index < 2:
                time.sleep(1)
        if any(sample != proof['frameworkSamples'][0] for sample in proof['frameworkSamples'][1:]):
            raise RuntimeError('Native framework restarted during readiness checks')
        crash = adb('logcat', '-b', 'crash', '-d')
        (out / 'framework-crash.log').write_text(crash + '\n')
        if re.search(r'Fatal signal[^\n]*(?:surfaceflinger|system_server)|'
                     r'FATAL EXCEPTION IN SYSTEM PROCESS|'
                     r'Process: system_server|hasReadColorBufferDma', crash):
            raise RuntimeError('Native framework crash detected before app execution')
        sdk = adb('shell', 'getprop', 'ro.build.version.sdk_full') or adb(
            'shell', 'getprop', 'ro.build.version.sdk')
        if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)?', sdk):
            raise RuntimeError('Native SDK version is unmeasured')
        version = tuple(int(part) for part in sdk.split('.'))
        proof['graphics'] = {'sdkVersion': sdk, 'dmaReadbackRequired': version >= (36, 1)}
        if proof['graphics']['dmaReadbackRequired']:
            graphics = adb('shell', 'dumpsys', '-t', '3', 'SurfaceFlinger')
            (out / 'framework-graphics.txt').write_text(graphics + '\n')
            required = ('ANDROID_EMU_read_color_buffer_dma', 'ANDROID_EMU_direct_mem',
                        'ANDROID_EMU_has_shared_slots_host_memory_allocator')
            extensions = set(graphics.split())
            proof['graphics']['requiredExtensions'] = list(required)
            proof['graphics']['missingExtensions'] = [name for name in required if name not in extensions]
            if proof['graphics']['missingExtensions']:
                raise RuntimeError('Native graphics lacks DMA readback; launch with '
                                   '-feature GLDirectMem,HasSharedSlotsHostMemoryAllocator')
        storage = adb('shell', 'df', '-k', '/data')
        (out / 'guest-data-space.txt').write_text(storage + '\n')
        rows = [line.split() for line in storage.splitlines()[1:] if line.strip()]
        if (len(rows) != 1 or len(rows[0]) != 6
                or not all(value.isdigit() for value in rows[0][1:4])
                or not rows[0][5].startswith('/data')):
            raise RuntimeError('Native userdata free space is unmeasured')
        # Cover the app, instrumentation, package installation and retained
        # output inside the guest; host AVD allocation alone cannot prove this.
        available = int(rows[0][3]) * 1024
        required = 512 * 1024**2
        proof['guestStorage'] = {'availableBytes': available, 'requiredBytes': required,
                                 'sufficient': available >= required}
        if available < required:
            raise RuntimeError('Insufficient native userdata space; use owned fresh userdata, '
                               'never erase a pre-existing AVD')
        proof['frameworkReady'] = True
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        proof['frameworkErrors'].append(str(error))
if not proof['bootCompleted'] or not proof['frameworkReady']:
    # The CI owner destroys its temporary guest after this check returns.
    # Retain bounded boot evidence now, including when the boot flag never
    # arrives. Diagnostic success cannot revive the failed readiness check.
    proof['failureDiagnostics'] = []
    for filename, command in (
            ('boot-properties.txt', ('shell', 'getprop')),
            ('framework-crash.log', ('logcat', '-b', 'crash', '-d', '-t', '200')),
            ('framework-system.log', ('logcat', '-b', 'system', '-d', '-t', '200'))):
        item = {'path': filename, 'timeoutSeconds': 8}
        try:
            text = adb(*command)
            if filename == 'boot-properties.txt':
                allowed = {'sys.boot_completed', 'init.svc.bootanim', 'init.svc.zygote',
                           'init.svc.zygote64', 'init.svc.surfaceflinger',
                           'init.svc.servicemanager', 'ro.build.version.sdk'}
                text = '\n'.join(line for line in text.splitlines()
                                 if line.partition(']:')[0].lstrip('[') in allowed)
            # Keep one bounded tail per owned-guest diagnostic, not arbitrary
            # guest properties or an unbounded log dump.
            text = '\n'.join(text.splitlines()[-200:])[-16384:]
            (out / filename).write_text(text + '\n')
            item['status'] = 'captured'
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
            item.update(status='unavailable', error=str(error)[:2000])
        proof['failureDiagnostics'].append(item)
(out / 'emulator-boot.json').write_text(json.dumps(proof, indent=2) + '\n')
if not proof['bootCompleted'] or not proof['frameworkReady']:
    errors = proof['frameworkErrors'] or [proof['adbError'] or 'boot completion property is not 1']
    raise SystemExit('Owned emulator is not healthy: ' + '; '.join(errors)
                     + '; evidence: ' + str(out / 'emulator-boot.json'))
PY
    exit
fi
if [[ "$mode" == verify-emulator ]]; then
    [[ -n "${ANDROID_HOME:-}" ]] || exit 2
    attempt_dir="${2:-android-ci-attempt}"
    if [[ -n "${3:-}" ]]; then
        # ADB discovers only the documented console-port range by default.
        # Reject ports outside it instead of relying on a remembered transport
        # from an earlier emulator or a manual adb connection.
        port="$3"
        # shellcheck disable=SC2015 # either check failing must reach the error branch
        [[ "$port" =~ ^[0-9]{4}$ ]] && (( port >= 5554 && port <= 5584 && port % 2 == 0 )) || {
            echo 'Android emulator console port must be even and between 5554 and 5584 for ADB discovery.' >&2
            exit 2
        }
    fi
    mkdir -p "$attempt_dir"
    if [[ -n "${4:-}" ]]; then
        # hw.ramSize is an integer in MiB, unlike disk-size's suffixed units.
        # A local 1536M value silently became 256 MiB and the API 36.1 guest
        # panicked before adbd started. Validate before waiting for transport.
        python3 - "$4" "$attempt_dir" <<'PY'
import json, re, sys
from pathlib import Path
config, out = Path(sys.argv[1]), Path(sys.argv[2])
values = [line.split('=', 1)[1].strip() for line in config.read_text().splitlines()
          if '=' in line and line.split('=', 1)[0].strip() == 'hw.ramSize']
valid = len(values) == 1 and re.fullmatch(r'[1-9][0-9]*', values[0]) is not None
memory = int(values[0]) if valid else None
proof = {'config': str(config), 'configuredValues': values,
         'memoryMiB': memory, 'requiredMiB': 4096,
         'sufficient': valid and memory >= 4096}
(out / 'emulator-memory.json').write_text(json.dumps(proof, indent=2) + '\n')
if not proof['sufficient']:
    raise SystemExit('Owned API 36 AVD requires hw.ramSize as an integer of at least 4096 MiB')
PY
    fi
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
if [[ "$mode" == release-runner-space ]]; then
    # The paired leg adds the operator checkout, its npm install and the host
    # bundle to a 75 GB runner root that ships 98% full. Run 37550640887 then
    # left 1.46 GB for an AVD needing 8.8 GB. Only the disposable, owned Actions
    # runner may delete preinstalled software. Android SDK, JDK, Node, Rust and
    # Python stay; every path below is a toolchain this job never invokes.
    [[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || {
        echo 'Runner space release requires a GitHub-hosted runner.' >&2
        exit 2
    }
    attempt_dir="${2:-android-ci-attempt}"
    mkdir -p "$attempt_dir"
    { echo "release-runner-space before $(date -u +%FT%TZ)"; df -Pk /; } >> "$attempt_dir/storage.txt"
    for path in /usr/share/dotnet /usr/local/.ghcup /opt/ghc /usr/share/swift \
        /opt/hostedtoolcache/CodeQL /opt/hostedtoolcache/PyPy /opt/hostedtoolcache/go \
        /usr/local/share/powershell /usr/local/share/boost /usr/local/share/chromium \
        /usr/local/julia* /opt/microsoft /opt/google /opt/az; do
        [[ -e "$path" ]] || continue
        sudo rm -rf --one-file-system "$path"
    done
    { echo "release-runner-space after $(date -u +%FT%TZ)"; df -Pk /; } >> "$attempt_dir/storage.txt"
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

# A phase that passes records a publication pass bound to the clean commit it
# started from (tools/build-scripts/android-release-provenance.sh checks-pass);
# release provenance refuses a candidate without both host and connected passes.
phase_start() {
    if [[ -z "$(git status --porcelain --untracked-files=normal)" ]]; then
        git rev-parse HEAD
    else
        echo dirty
    fi
}

if [[ "$mode" != connected ]]; then
    host_start="$(phase_start)"
    cargo fmt --all -- --check
    cargo clippy --workspace --all-targets -- -D warnings
    cargo test --workspace --all-targets
    make bindings-smoke test-android-java test-android-launch-lifecycle \
        test-android-release-provenance test-android-signing test-android-library-notices test-android-runner test-android-ci
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
    tools/build-scripts/android-release-provenance.sh checks-pass host "$host_start"
fi

if [[ "$mode" != host ]]; then
    bash "$0" verify-native-dependencies
    connected_start="$(phase_start)"
    mapfile -t devices < <(adb devices | awk 'NR>1 && $2=="device"{print $1}')
    if [[ -n "${ANDROID_SERIAL:-}" ]]; then
        device="$ANDROID_SERIAL"
        printf '%s\n' "${devices[@]}" | grep -Fxq "$device" || {
            echo 'The explicitly owned Android test device is not connected.' >&2
            exit 1
        }
    else
        [[ ${#devices[@]} == 1 ]] || {
            echo 'Android native gate requires ANDROID_SERIAL or exactly one connected test device.' >&2
            exit 1
        }
        device="${devices[0]}"
    fi
    export ANDROID_SERIAL="$device"
    [[ "$(adb -s "$device" shell getprop sys.boot_completed | tr -d '\r')" == 1 ]]
    [[ "$(adb -s "$device" shell getprop ro.build.version.sdk | tr -d '\r')" == 36 ]]
    [[ "$(adb -s "$device" shell getconf PAGE_SIZE | tr -d '\r')" == 16384 ]]
    bash "$0" verify-emulator-boot "$device" android/app/build/ci-evidence/connected-emulator-preflight 1
    adb -s "$device" shell pm path android | grep -q '^package:'
    bash tools/build-scripts/install-and-launch.sh
    rm -rf android/app/build/outputs/androidTest-results/connected/debug
    sealed_operator="${PAPERCUP_PAPERCUSP_ROOT:-$ROOT/../papercusp}"
    [[ ! -d "$ROOT/android-ci-attempt/operator/node_modules/tsx" ]] || sealed_operator="$ROOT/android-ci-attempt/operator"
    ANDROID_SERIAL="$device" bash "$0" sealed-native \
        "android/app/build/ci-evidence/sealed-native-$(date -u +%Y%m%dT%H%M%SZ)" "$sealed_operator" all
    verify_results android/app/build connected
    tools/build-scripts/android-release-provenance.sh checks-pass connected "$connected_start"
fi

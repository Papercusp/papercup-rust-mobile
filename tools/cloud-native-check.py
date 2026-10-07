#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Public-cloud mode of run-android-checks.sh; no local responder or URL rewrite."""
import base64
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import stat
import subprocess
import sys
from urllib.parse import urlsplit
import uuid


def validate_input(path, serial, expected_base):
    if not re.fullmatch(r'emulator-[0-9]+', serial):
        raise ValueError('cloud-native requires explicit owned ANDROID_SERIAL')
    path = Path(path)
    if stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise ValueError('Fresh QR file must be private (mode 0600)')
    qr = json.loads(path.read_text())
    base = qr.get('server', '')
    url = urlsplit(base)
    host = url.hostname or ''
    if (url.scheme != 'https' or not host or url.username or url.password
            or url.query or url.fragment or url.port not in (None, 443)
            or host in ('localhost',) or host.endswith(('.localhost', '.local'))
            or not re.fullmatch(r'/api/workspaces/[a-zA-Z0-9_-]+', url.path)):
        raise ValueError('Cloud QR requires public HTTPS workspace relay base')
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
    if address is not None and not address.is_global:
        raise ValueError('Cloud QR must not use a LAN or loopback address')
    if not expected_base or base != expected_base:
        raise ValueError('Fresh QR base must match explicit PAPERCUP_CLOUD_BASE')
    if not qr.get('pairToken') or not qr.get('workspaceId'):
        raise ValueError('Fresh QR is missing pairing token or workspace')
    try:
        pin = base64.b64decode(qr.get('noiseKey', ''), validate=True)
    except (ValueError, TypeError):
        pin = b''
    if len(pin) != 32:
        raise ValueError('Cloud QR must carry a 32-byte machine Noise pin')
    return qr


def capture_apk(source, destination):
    # Hash the held bytes, then recheck the shared source: never label an old
    # historical interop hash as the current installed candidate.
    source, destination = Path(source), Path(destination)
    before = hashlib.sha256(source.read_bytes()).hexdigest()
    shutil.copyfile(source, destination)
    captured = hashlib.sha256(destination.read_bytes()).hexdigest()
    after = hashlib.sha256(source.read_bytes()).hexdigest()
    if before != captured or captured != after:
        destination.unlink(missing_ok=True)
        raise ValueError('Shared APK advanced during capture; candidate refused')
    return captured


def verify_proof(proof, run_id, workspace, output):
    required = ('encryptedRestore', 'reconnectAndScope', 'readOperations',
                'navigation', 'revoked', 'revokedTokenRejected', 'credentialsCleared')
    if (proof.get('runId') != run_id or proof.get('workspaceId') != workspace
            or proof.get('stage') != 'completed'
            or not all(proof.get(key) is True for key in required)
            or not re.search(r'OK \(1 test\)', output)
            or 'INSTRUMENTATION_CODE: -1' not in output
            or 'FAILURES!!!' in output):
        raise ValueError('Cloud native journey incomplete; inspect retained stage proof')


def inject_pairing_input(adb, app, payload):
    # A fresh install has no app files directory until an Activity creates it.
    # Prepare only our owned input; exclusive creation preserves prior evidence.
    adb('shell', 'run-as', app, 'mkdir', '-p', 'files', check=True)
    adb('shell', 'run-as', app, 'test', '!', '-e', 'files/cloud-pairing-input.json', check=True)
    adb('shell', 'run-as ' + app + ' sh -c ' + shlex.quote(
        'umask 077; set -C; cat > files/cloud-pairing-input.json'), input=payload, check=True)


def main():
    out, qr_file = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    serial = os.environ.get('ANDROID_SERIAL', '')
    qr = validate_input(qr_file, serial, os.environ.get('PAPERCUP_CLOUD_BASE', ''))
    out.mkdir(parents=True, exist_ok=False)
    out.chmod(0o700)
    run_id = uuid.uuid4().hex
    app = 'com.papercuspai.operator.mobile'
    def adb(*args, **kwargs):
        return subprocess.run(['adb', '-s', serial, *args], capture_output=True,
                              text=True, timeout=kwargs.pop('timeout', 45), **kwargs)
    result = {'runId': run_id, 'serial': serial, 'base': qr['server'],
              'workspaceId': qr['workspaceId'], 'exitCode': 1,
              'scope': 'public hosted Android debug manual QR/JNI; no camera, BYOC, signed candidate or complete P015 claim',
              'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
              'sourceDirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True)),
              'sourceFingerprints': {path: hashlib.sha256(Path(path).read_bytes()).hexdigest() for path in (
                  'tools/run-android-checks.sh', 'tools/cloud-native-check.py',
                  'android/app/src/androidTest/kotlin/com/papercuspai/operator/mobile/PapercupAppSmokeTest.kt',
                  'android/app/src/main/kotlin/com/papercuspai/operator/mobile/PairScreen.kt',
                  'android/app/src/main/kotlin/com/papercuspai/operator/mobile/Credentials.kt')}}
    injected = False
    try:
        # Other agents' connected devices are permitted and never selected.
        devices = subprocess.check_output(['adb', 'devices'], text=True)
        serials = [row.split()[0] for row in devices.splitlines()
                   if len(row.split()) == 2 and row.split()[1] == 'device']
        if serial not in serials:
            raise ValueError('Explicit owned emulator is not connected')
        subprocess.run(['bash', 'tools/run-android-checks.sh', 'verify-emulator-boot',
                        serial, str(out / 'preflight'), '1'], check=True, timeout=60)
        for args, value in [(('shell', 'getprop', 'ro.build.version.sdk'), '36'),
                            (('shell', 'getconf', 'PAGE_SIZE'), '16384')]:
            if adb(*args, check=True).stdout.strip() != value:
                raise ValueError('Cloud native requires API36 and 16KB pages')
        env = dict(os.environ)
        env['JAVA_HOME'] = subprocess.check_output(
            ['bash', 'tools/build-scripts/resolve-java-home.sh'], text=True).strip()
        with (out / 'build.log').open('w') as log:
            subprocess.run(['bash', 'tools/build-scripts/build-android.sh', 'debug'],
                           env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=7200)
            subprocess.run(['android/gradlew', '-p', 'android', ':app:assembleDebugAndroidTest', '--console=plain'],
                           env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=2400)
        for source, name in [('android/app/build/outputs/apk/debug/app-debug.apk', 'app.apk'),
                             ('android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk', 'test.apk')]:
            result[name + 'Sha256'] = capture_apk(source, out / name)
            adb('install', '-r', str(out / name), timeout=120, check=True)
        installed = adb('shell', 'pm', 'path', app, check=True).stdout.strip().removeprefix('package:')
        adb('pull', installed, str(out / 'installed.apk'), timeout=120, check=True)
        if hashlib.sha256((out / 'installed.apk').read_bytes()).hexdigest() != result['app.apkSha256']:
            raise ValueError('Installed APK does not match captured candidate')
        result['installedApkMatches'] = True
        # A large build must not silently reuse a changed/replaced QR file.
        if validate_input(qr_file, serial, qr['server']) != qr:
            raise ValueError('Fresh QR changed during build')
        payload = json.dumps({'runId': run_id, 'pairPayload': qr})
        inject_pairing_input(adb, app, payload)
        injected = True
        run = adb('shell', 'am', 'instrument', '-w', '-r', '-e', 'class',
                  app + '.PapercupAppSmokeTest#launcherActivityStarts', '-e', 'cloudPairing', 'true',
                  app + '.test/androidx.test.runner.AndroidJUnitRunner', timeout=300)
        (out / 'instrumentation.log').write_text(run.stdout + run.stderr)
        proof = json.loads(adb('shell', 'run-as', app, 'cat',
                              'files/cloud-pairing-result.json', check=True).stdout)
        result['journey'] = proof
        verify_proof(proof, run_id, qr['workspaceId'], run.stdout)
        if run.returncode:
            raise ValueError('Instrumentation command failed')
        result['exitCode'] = 0
    finally:
        if injected:
            if 'journey' not in result:
                saved = adb('shell', 'run-as', app, 'cat', 'files/cloud-pairing-result.json')
                try:
                    result['journey'] = json.loads(saved.stdout)
                except ValueError:
                    result['cleanupUnknown'] = True
            adb('shell', 'run-as', app, 'rm', '-f', 'files/cloud-pairing-input.json')
        (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Cloud native scoped journey passed; retained immutable APK and proof: ' + str(out))


if __name__ == '__main__':
    main()

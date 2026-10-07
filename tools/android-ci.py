#!/usr/bin/env python3
"""Independent Android CI, reusing the maintained host and native gates."""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
IMAGE = 'system-images;android-36;google_apis_ps16k;x86_64'


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def output(command, root, env=None):
    return subprocess.check_output(command, cwd=root, env=env, text=True,
                                   stderr=subprocess.STDOUT, timeout=60).strip()


def source_identity(root):
    commit = output(['git', 'rev-parse', 'HEAD'], root)
    paths = subprocess.check_output(['git', 'ls-files', '-z', '--cached'], cwd=root).split(b'\0')
    h = hashlib.sha256()
    for raw in sorted(p for p in paths if p):
        path = root / os.fsdecode(raw)
        h.update(raw + b'\0')
        if path.is_file():
            h.update(path.read_bytes())
        elif path.is_dir():
            h.update(output(['git', '-C', str(path), 'rev-parse', 'HEAD'], root).encode())
        else:
            h.update(b'missing')
    # Include new source files, without ever retaining their content as evidence.
    untracked = subprocess.check_output(['git', 'ls-files', '-z', '--others', '--exclude-standard'], cwd=root)
    for raw in sorted(p for p in untracked.split(b'\0') if p):
        path = root / os.fsdecode(raw)
        h.update(raw + b'\0')
        if path.is_file():
            h.update(path.read_bytes())
    modules = output(['git', 'submodule', 'status', '--recursive'], root)
    if any(line.startswith(('+', '-', 'U')) for line in modules.splitlines()):
        raise ValueError('Uninitialized or mismatched submodule; CI refused')
    h.update(modules.encode())
    return {'commit': commit, 'fingerprint': h.hexdigest(),
            'dirty': bool(output(['git', 'status', '--porcelain'], root))}


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def run_phase(name, command, root, env, attempt, phases, timeout=5400):
    log = attempt / (name + '.log')
    with log.open('w') as stream:
        child = subprocess.Popen(command, cwd=root, env=env, stdout=stream,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=timeout)
        except BaseException:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            raise
    phases.append({'name': name, 'exitCode': code, 'log': str(log), 'sha256': digest(log)})
    if code:
        raise RuntimeError(f'{name} exited {code}; see {log}')


def choose_emulator_port():
    for port in range(5660, 5682, 2):
        sockets = [socket.socket(), socket.socket()]
        try:
            sockets[0].bind(('127.0.0.1', port))
            sockets[1].bind(('127.0.0.1', port + 1))
            return port
        except OSError:
            pass
        finally:
            for sock in sockets:
                sock.close()
    raise RuntimeError('No available owned emulator port')


def collect_artifacts(root, attempt):
    # Deliberately exclude source checkouts, private dependencies and configuration.
    build = root / 'android/app/build'
    retained = attempt / 'artifacts'
    for relative in ('test-results', 'reports', 'outputs/androidTest-results',
                     'outputs/apk/debug/app-debug.apk',
                     'outputs/apk/androidTest/debug/app-debug-androidTest.apk'):
        source = build / relative
        target = retained / relative
        if source.is_dir():
            shutil.copytree(source, target, dirs_exist_ok=True)
        elif source.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
    return [{'path': str(p.relative_to(attempt)), 'sha256': digest(p)}
            for p in sorted(attempt.rglob('*')) if p.is_file() and p.name != 'result.json']


def cached_proof(state, identity, counterpart):
    try:
        proof = json.loads((state / 'success.json').read_text())
        if (proof['source'] != identity or proof['operator'] != counterpart
                or proof['week'] != dt.datetime.now(dt.timezone.utc).strftime('%G-%V')
                or proof['status'] != 'passed'):
            return None
        attempt = Path(proof['attempt']).resolve()
        if not attempt.is_relative_to((state / 'attempts').resolve()):
            return None
        required = {'host', 'connected', 'paired', 'verify-paired'}
        if required - {p['name'] for p in proof['phases'] if p['exitCode'] == 0}:
            return None
        if not proof['artifacts']:
            return None
        for record in proof['artifacts']:
            path = (attempt / record['path']).resolve()
            if not path.is_relative_to(attempt) or digest(path) != record['sha256']:
                return None
        return proof
    except (OSError, KeyError, ValueError, TypeError):
        return None


def execute(root, operator, state, force=False, preflight_only=False):
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
    attempt = state / 'attempts' / stamp
    attempt.mkdir(parents=True)
    result = {'schemaVersion': 1, 'executor': 'local-systemd', 'attempt': str(attempt),
              'status': 'failed', 'startedAt': stamp, 'phases': [],
              'scope': 'Android working-build host/native CI; phone, signing and Play acceptance remain separate'}
    env = os.environ.copy()
    sdk = Path(env.get('ANDROID_HOME', str(Path.home() / 'Android/Sdk')))
    env['ANDROID_HOME'] = str(sdk)
    env['ANDROID_NDK_HOME'] = str(sdk / 'ndk/27.0.12077973')
    env['CARGO_HOME'] = env.get('CARGO_HOME', str(Path.home() / '.cargo'))
    env['RUSTUP_HOME'] = env.get('RUSTUP_HOME', str(Path.home() / '.rustup'))
    env['PATH'] = str(Path(env['CARGO_HOME']) / 'bin') + ':' + str(sdk / 'platform-tools') + ':' + env['PATH']
    emulator = None
    avd_root = None
    try:
        identity = source_identity(root)
        result['source'] = identity
        result['operator'] = {'commit': output(['git', 'rev-parse', 'HEAD'], operator),
                              'root': str(operator)}
        env['JAVA_HOME'] = output(['bash', 'tools/build-scripts/resolve-java-home.sh'], root, env)
        env['PAPERCUP_PAPERCUSP_ROOT'] = str(operator)
        node = output(['node', '--version'], root, env)
        if not node.startswith('v25.'):
            raise ValueError('The Android operator counterpart requires Node 25')
        fresh = ['node', str(operator / 'apps/operator/bin/bundle-host-freshness.mjs'), 'check',
                 '--repo-root', str(operator), '--entry', 'apps/operator/bin/hono-host.ts',
                 '--outfile', 'apps/operator/dist-host/hono-host.mjs',
                 '--manifest', 'apps/operator/dist-host/.bundle-fresh.json']
        run_phase('operator-freshness', fresh, operator, env, attempt, result['phases'], 60)
        run_phase('rust-preflight', ['bash', 'tools/run-android-checks.sh', 'verify-rust-toolchain'],
                  root, env, attempt, result['phases'], 60)
        run_phase('emulator-preflight', ['bash', 'tools/run-android-checks.sh', 'verify-emulator', str(attempt)],
                  root, env, attempt, result['phases'], 60)
        run_phase('avd-space-preflight', ['bash', 'tools/run-android-checks.sh', 'verify-avd-space', '6144M', str(attempt)],
                  root, env, attempt, result['phases'], 60)
        if not (sdk / 'system-images/android-36/google_apis_ps16k/x86_64/system.img').is_file():
            raise ValueError('Required API 36 / 16 KB system image is missing')
        if not os.access('/dev/kvm', os.R_OK | os.W_OK):
            raise ValueError('Owned native execution requires accessible /dev/kvm')
        if preflight_only:
            result['status'] = 'preflight-passed'
            return 0
        proof = None if force else cached_proof(state, identity, result['operator'])
        if proof:
            run_phase('verify-cached-paired', ['bash', 'tools/run-android-checks.sh', 'verify-isolated-native',
                      str(Path(proof['attempt']) / 'paired'), result['operator']['commit']],
                      root, env, attempt, result['phases'], 60)
            result.update(status='reused', proofAttempt=proof['attempt'])
            return 0
        # Remove admission BEFORE executing: a failure cannot revive an older green.
        (state / 'success.json').unlink(missing_ok=True)
        run_phase('host', ['make', 'check-android-host', 'tokens-check'], root, env, attempt, result['phases'])
        candidates = sorted(sdk.glob('cmdline-tools/*/bin/avdmanager'))
        if not candidates:
            raise ValueError('avdmanager is missing')
        avd_root = Path(tempfile.mkdtemp(prefix='android-ci-avd-', dir=state))
        env['ANDROID_AVD_HOME'] = str(avd_root)
        name = 'papercusp-ci-' + uuid.uuid4().hex[:12]
        command = [str(candidates[-1]), 'create', 'avd', '-n', name, '-k', IMAGE,
                   '-p', str(avd_root / (name + '.avd'))]
        with (attempt / 'avd-create.log').open('w') as log:
            subprocess.run(command, cwd=root, env=env, input='no\n', text=True,
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
        port = choose_emulator_port()
        env['ANDROID_SERIAL'] = f'emulator-{port}'
        result['emulatorSerial'] = env['ANDROID_SERIAL']
        with (attempt / 'emulator.log').open('w') as log:
            emulator = subprocess.Popen([str(sdk / 'emulator/emulator'), '-avd', name, '-port', str(port),
                '-no-window', '-no-snapshot', '-gpu', 'swiftshader', '-memory', '4096',
                '-feature', 'GLDirectMem,HasSharedSlotsHostMemoryAllocator', '-partition-size', '6144',
                '-noaudio', '-no-boot-anim'], env=env, stdout=log, stderr=subprocess.STDOUT)
        run_phase('boot', ['bash', 'tools/run-android-checks.sh', 'verify-emulator-boot',
                          env['ANDROID_SERIAL'], str(attempt / 'boot'), '180'], root, env, attempt, result['phases'], 240)
        if emulator.poll() is not None:
            raise RuntimeError('Owned emulator exited before native execution')
        run_phase('connected', ['bash', 'tools/run-android-checks.sh', 'connected'], root, env, attempt, result['phases'], 1800)
        shutil.copytree(root / 'android/app/build/outputs/androidTest-results/connected',
                        attempt / 'unpaired-native-results')
        run_phase('paired', ['bash', 'tools/run-android-checks.sh', 'isolated-native',
                            str(operator), str(attempt / 'paired'), 'features'], root, env, attempt, result['phases'], 1800)
        run_phase('verify-paired', ['bash', 'tools/run-android-checks.sh', 'verify-isolated-native',
                  str(attempt / 'paired'), result['operator']['commit']], root, env, attempt, result['phases'], 60)
        if source_identity(root) != identity or output(['git', 'rev-parse', 'HEAD'], operator) != result['operator']['commit']:
            raise RuntimeError('Source/counterpart changed during verification; admission refused')
        run_phase('operator-freshness-end', fresh, operator, env, attempt, result['phases'], 60)
        result.update(status='passed', week=dt.datetime.now(dt.timezone.utc).strftime('%G-%V'))
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        result['error'] = str(error)
        print(result['error'], flush=True)
        (state / 'success.json').unlink(missing_ok=True)
        return 1
    finally:
        if emulator is not None:
            emulator.terminate()
            try:
                emulator.wait(timeout=15)
            except subprocess.TimeoutExpired:
                emulator.kill()
                emulator.wait()
            result['emulatorCleanupVerified'] = emulator.poll() is not None
        if avd_root is not None:
            shutil.rmtree(avd_root)
        result['artifacts'] = collect_artifacts(root, attempt)
        result['finishedAt'] = dt.datetime.now(dt.timezone.utc).isoformat()
        write_json(attempt / 'result.json', result)
        write_json(state / 'latest.json', result)
        if result['status'] == 'passed':
            write_json(state / 'success.json', result)
        print(json.dumps({'status': result['status'], 'evidence': str(attempt / 'result.json')}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--force', action='store_true')
    parser.add_argument('--preflight', action='store_true')
    args = parser.parse_args()
    state = Path(os.environ.get('PAPERCUP_ANDROID_CI_STATE', str(Path.home() / '.local/state/papercusp/android-ci'))).resolve()
    state.mkdir(parents=True, exist_ok=True)
    operator = Path(os.environ.get('PAPERCUP_OPERATOR_DIR', str(ROOT.parent / 'papercusp'))).resolve()
    with (state / 'executor.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('Android CI is already running; overlapping execution skipped')
            return 0
        return execute(ROOT, operator, state, args.force, args.preflight)


if __name__ == '__main__':
    raise SystemExit(main())

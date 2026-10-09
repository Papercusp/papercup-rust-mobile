#!/usr/bin/env python3
"""Independent Android CI, reusing the maintained host and native gates."""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
IMAGE = 'system-images;android-36;google_apis_ps16k;x86_64'
CI_ADMISSION = 'android/app/build/outputs/papercusp-android-checks/ci.json'


def executor_state():
    state = Path(os.environ.get('PAPERCUP_ANDROID_CI_STATE',
                 str(Path.home() / '.local/state/papercusp/android-ci'))).resolve()
    state.mkdir(parents=True, exist_ok=True)
    state.chmod(0o700)
    return state


def inherited_executor(env):
    value = env.get('PAPERCUP_ANDROID_EXECUTOR_FD')
    if value is None:
        return None
    try:
        fd = int(value)
        expected = (Path(env['PAPERCUP_ANDROID_CI_STATE']) / 'executor.lock').stat()
        try:
            held = os.fstat(fd)
        except OSError:
            held = None
        if held is None or (held.st_dev, held.st_ino) != (expected.st_dev, expected.st_ino):
            # Node/private-runtime and Python subprocess adapters close extra
            # descriptors. Permit their descendant only while the verified
            # ancestor still owns this exact FD and the mutex remains held.
            owner = int(env['PAPERCUP_ANDROID_EXECUTOR_PID'])
            ancestor = os.getppid()
            for _ in range(128):
                if ancestor == owner:
                    break
                if ancestor <= 1:
                    raise ValueError('executor owner is not an ancestor')
                fields = Path(f'/proc/{ancestor}/stat').read_text().rsplit(')', 1)[1].split()
                ancestor = int(fields[1])
            else:
                raise ValueError('executor ancestry exceeds bound')
            owner_fd = Path(f'/proc/{owner}/fd/{fd}').stat()
            if (owner_fd.st_dev, owner_fd.st_ino) != (expected.st_dev, expected.st_ino):
                raise ValueError('ancestor executor descriptor differs')
            with (Path(env['PAPERCUP_ANDROID_CI_STATE']) / 'executor.lock').open('a+') as probe:
                try:
                    fcntl.flock(probe.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    return None
            raise ValueError('ancestor executor is no longer held')
        if (not stat.S_ISREG(held.st_mode)
                or (held.st_dev, held.st_ino) != (expected.st_dev, expected.st_ino)):
            raise ValueError('foreign executor descriptor')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except (KeyError, OSError, ValueError) as error:
        raise ValueError('Invalid inherited Android executor custody') from error


def executor_command(command):
    if not command:
        raise ValueError('Executor command is required')
    state = executor_state()
    env = dict(os.environ, PAPERCUP_ANDROID_CI_STATE=str(state))
    fd = inherited_executor(env)
    if 'PAPERCUP_ANDROID_EXECUTOR_FD' in env:
        return subprocess.call(command, env=env, pass_fds=(() if fd is None else (fd,)))
    with (state / 'executor.lock').open('a+') as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('Android executor custody is held; output writer refused', file=sys.stderr)
            return 73
        env['PAPERCUP_ANDROID_EXECUTOR_FD'] = str(lock.fileno())
        env['PAPERCUP_ANDROID_EXECUTOR_PID'] = str(os.getpid())
        # A producer must not leave a Gradle daemon holding its executor FD.
        env['GRADLE_OPTS'] = env.get('GRADLE_OPTS', '') + ' -Dorg.gradle.daemon=false'
        return subprocess.call(command, env=env, pass_fds=(lock.fileno(),))


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
            h.update(json.dumps(source_identity(path), sort_keys=True).encode())
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
    firebase = root / 'android/app/google-services.json'
    if firebase.is_file():
        h.update(b'firebase-config\0' + firebase.read_bytes())
    return {'commit': commit, 'fingerprint': h.hexdigest(),
            'dirty': bool(output(['git', 'status', '--porcelain'], root))}


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def required_tools(env):
    commands = ('git', 'make', 'node', 'python3', 'cargo', 'rustc', 'rustup',
                'adb', 'rg', 'readelf', 'nm', 'unzip', 'zip', 'cc', 'curl',
                'openssl', 'timeout', 'tar', 'gzip', 'sha256sum', 'flock')
    missing = [command for command in commands if not shutil.which(command, path=env['PATH'])]
    if missing:
        raise ValueError('Missing required Android CI tools: ' + ', '.join(missing))


def run_phase(name, command, root, env, attempt, phases, timeout=5400):
    log = attempt / (name + '.log')
    print(f'Android CI phase: {name}; log: {log}', flush=True)
    executor_fd = inherited_executor(env)
    with log.open('w') as stream:
        child = subprocess.Popen(command, cwd=root, env=env, stdout=stream,
                                 stderr=subprocess.STDOUT, start_new_session=True,
                                 pass_fds=(() if executor_fd is None else (executor_fd,)))
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


def prune_attempts(state, keep=16):
    protected = set()
    for name in ('latest.json', 'success.json'):
        try:
            protected.add(Path(json.loads((state / name).read_text())['attempt']).resolve())
        except (OSError, ValueError, KeyError):
            pass
    attempts = state / 'attempts'
    if not attempts.is_dir():
        return
    owned = sorted((p for p in attempts.iterdir() if p.is_dir() and not p.is_symlink()
                    and re.fullmatch(r'\d{8}T\d{6}Z-[0-9a-f]{8}', p.name)), reverse=True)
    for path in owned[keep:]:
        if path.resolve() in protected or not (path / 'result.json').is_file():
            continue
        try:
            result = json.loads((path / 'result.json').read_text())
            if result.get('executor') == 'local-systemd' and Path(result['attempt']).resolve() == path.resolve():
                shutil.rmtree(path)
        except (OSError, KeyError, ValueError):
            continue


def execute(root, operator, state, force=False, preflight_only=False):
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
    attempt = state / 'attempts' / stamp
    attempt.mkdir(parents=True)
    result = {'schemaVersion': 1, 'executor': 'local-systemd', 'attempt': str(attempt),
              'status': 'failed', 'startedAt': dt.datetime.now(dt.timezone.utc).isoformat(), 'phases': [],
              'scope': 'Android working-build host/native CI; phone, signing and Play acceptance remain separate'}
    env = os.environ.copy()
    sdk = Path(env.get('ANDROID_HOME', str(Path.home() / 'Android/Sdk')))
    env['ANDROID_HOME'] = str(sdk)
    env['ANDROID_NDK_HOME'] = str(sdk / 'ndk/27.0.12077973')
    env['CARGO_HOME'] = env.get('CARGO_HOME', str(Path.home() / '.cargo'))
    env['RUSTUP_HOME'] = env.get('RUSTUP_HOME', str(Path.home() / '.rustup'))
    env['PATH'] = str(Path(env['CARGO_HOME']) / 'bin') + ':' + str(sdk / 'platform-tools') + ':' + env['PATH']
    # Owned AVDs are created beneath state, which can be on a different
    # filesystem from the user's default AVD directory. Measure this parent
    # before creating the per-run directory, then select that directory below.
    env['ANDROID_AVD_HOME'] = str(state)
    emulator = None
    avd_root = None
    (root / CI_ADMISSION).unlink(missing_ok=True)
    try:
        required_tools(env)
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
            run_phase('ci-admission', ['bash', 'tools/build-scripts/android-release-provenance.sh',
                      'checks-pass', 'ci', identity['commit'] if not identity['dirty'] else 'dirty'],
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
        run_phase('ci-admission', ['bash', 'tools/build-scripts/android-release-provenance.sh',
                  'checks-pass', 'ci', identity['commit'] if not identity['dirty'] else 'dirty'],
                  root, env, attempt, result['phases'], 60)
        result.update(status='passed', week=dt.datetime.now(dt.timezone.utc).strftime('%G-%V'))
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        result['error'] = str(error)
        print(result['error'], flush=True)
        (state / 'success.json').unlink(missing_ok=True)
        (root / CI_ADMISSION).unlink(missing_ok=True)
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
    parser.add_argument('--pinned', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--exclusive-command', nargs=argparse.REMAINDER,
                        help='Run a maintained output producer under the shared executor')
    parser.add_argument('--verify-executor', action='store_true', help=argparse.SUPPRESS)
    argv = sys.argv[1:]
    command_index = argv.index('--exclusive-command') if '--exclusive-command' in argv else None
    # argparse treats a literal -- as its own terminator even with REMAINDER.
    # Parse our options separately so private-runtime and producer arguments
    # arrive byte-for-byte, including their command separator.
    args = parser.parse_args(argv if command_index is None else argv[:command_index])
    if args.verify_executor:
        if 'PAPERCUP_ANDROID_EXECUTOR_FD' not in os.environ:
            raise ValueError('Inherited Android executor custody is required')
        inherited_executor(os.environ)
        return 0
    if command_index is not None:
        return executor_command(argv[command_index + 1:])
    if not args.pinned:
        # Reuse staging GC's pin protocol: resolve under its lock and re-exec
        # so the immutable physical root is visible in /proc before releasing.
        pin = os.open('/tmp/papercup-staging-sync.lock', os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(pin, fcntl.LOCK_SH)
        os.set_inheritable(pin, True)
        operator = Path(os.environ.get('PAPERCUP_OPERATOR_DIR',
                        str(ROOT.parent / 'papercusp-staging.current'))).resolve()
        env = dict(os.environ, PAPERCUP_OPERATOR_DIR=str(operator),
                   PAPERCUSP_INTEGRATION_ROOT=str(operator), PAPERCUP_ANDROID_CI_PIN_FD=str(pin))
        os.execve(sys.executable, [sys.executable, str(Path(__file__).resolve()), '--pinned', *sys.argv[1:]], env)
    pin = int(os.environ.pop('PAPERCUP_ANDROID_CI_PIN_FD'))
    os.close(pin)
    state = executor_state()
    os.environ['PAPERCUP_ANDROID_CI_STATE'] = str(state)
    operator = Path(os.environ['PAPERCUP_OPERATOR_DIR']).resolve()
    with (state / 'executor.lock').open('a+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('Android CI is already running; overlapping execution skipped')
            return 0
        os.environ['PAPERCUP_ANDROID_EXECUTOR_FD'] = str(lock.fileno())
        os.environ['PAPERCUP_ANDROID_EXECUTOR_PID'] = str(os.getpid())
        os.environ['GRADLE_OPTS'] = os.environ.get('GRADLE_OPTS', '') + ' -Dorg.gradle.daemon=false'
        prune_attempts(state)
        return execute(ROOT, operator, state, args.force, args.preflight)


if __name__ == '__main__':
    raise SystemExit(main())

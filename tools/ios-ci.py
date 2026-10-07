#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Native iPhone verification and explicit signed delivery; no Actions dependency."""
import argparse
import datetime as dt
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('mobile_ci', ROOT / 'tools/android-ci.py')
mobile_ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mobile_ci)
# Share source/submodule identity, atomic evidence writes and bounded process groups
# with the maintained Android executor instead of introducing another CI service.
source_identity = mobile_ci.source_identity
write_json = mobile_ci.write_json
digest = mobile_ci.digest
SIGNING_KEYS = ('APPLE_TEAM_ID', 'IOS_DIST_CERT_P12_BASE64', 'IOS_DIST_CERT_PASSWORD',
                'IOS_APPSTORE_PROFILE_BASE64', 'ASC_API_KEY_ID', 'ASC_API_ISSUER_ID',
                'ASC_API_KEY_P8_BASE64')
SMOKE_TESTS = (
    'PapercupUITests/PairFlowUITests/testFreshLaunchShowsPairChoices',
    'PapercupUITests/CloudWorkspaceOfflineUITests/testCloudWorkspaceOfflineThenRecoversWithoutRepairing',
    'PapercupUITests/CloudWorkspaceOfflineUITests/testCloudWorkspaceShowsRelayLabelInSettings',
)


class SigningCleanupError(RuntimeError):
    """Evidence was written, but temporary signing cleanup failed."""


def run_phase(name, command, root, env, attempt, phases, **kwargs):
    # Native tools can echo environment values on failure. Redact before hashing
    # or retaining a log, including when the shared process runner raises.
    try:
        return mobile_ci.run_phase(name, command, root, env, attempt, phases, **kwargs)
    finally:
        log = attempt / (name + '.log')
        if log.is_file():
            text = log.read_text(errors='replace')
            secrets = [env.get(key, '') for key in SIGNING_KEYS[1:]]
            payload = env.get('TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD', '')
            if payload:
                secrets.append(payload)
                try:
                    values = json.loads(payload)
                    if isinstance(values, dict):
                        secrets.extend(v for v in values.values() if isinstance(v, str))
                except ValueError:
                    pass
            for value in sorted(set(secrets), key=len, reverse=True):
                if value:
                    text = text.replace(value, '[REDACTED]')
                    text = text.replace(json.dumps(value)[1:-1], '[REDACTED]')
            log.write_text(text)
            if not any(phase['name'] == name for phase in phases):
                phases.append({'name': name, 'exitCode': None, 'log': str(log),
                               'status': 'interrupted'})
            for phase in phases:
                if phase['name'] == name:
                    phase['sha256'] = digest(log)


def output(command, root, env):
    return mobile_ci.output(command, root, env)


def private_input(path, root):
    path = Path(path).resolve()
    if path.is_relative_to(root.resolve()):
        raise ValueError('Private input must be outside the repository')
    if not path.is_file() or path.stat().st_mode & 0o077:
        raise ValueError('Private input must be an owner-only regular file')
    return path


def load_signing(path, root, env):
    if path:
        values = json.loads(private_input(path, root).read_text())
        if not isinstance(values, dict) or set(values) != set(SIGNING_KEYS):
            raise ValueError('Signing JSON must contain exactly the seven signing inputs')
        if any(not isinstance(v, str) or not v for v in values.values()):
            raise ValueError('Signing inputs must be nonempty strings')
        env.update(values)
    subprocess.run(['bash', 'tools/build-scripts/ios-ci-signing.sh', 'require-secrets'],
                   cwd=root, env=env, check=True)


def toolchain(root, env):
    if platform.system() != 'Darwin':
        raise ValueError('Native iPhone execution requires macOS')
    missing = [name for name in ('git', 'make', 'node', 'python3', 'rustup', 'rustc',
                                'xcrun', 'xcodebuild', 'xcodegen', 'security')
               if not shutil.which(name, path=env['PATH'])]
    if missing:
        raise ValueError('Missing native iPhone tools: ' + ', '.join(missing))
    sdk = output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], root, env)
    if not re.fullmatch(r'\d+(?:\.\d+)*', sdk) or int(sdk.split('.')[0]) < 26:
        raise ValueError('iPhoneOS SDK26+ is required; found ' + sdk)
    xcode = output(['xcodebuild', '-version'], root, env)
    if not re.match(r'Xcode (?:2[6-9]|[3-9]\d)\.', xcode):
        raise ValueError('Xcode26+ is required; found ' + xcode)
    sims = json.loads(output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], root, env))
    devices = [d for runtime, rows in sims['devices'].items() if 'iOS-26' in runtime
               for d in rows if d.get('isAvailable') and d.get('name', '').startswith('iPhone')]
    selected = env.get('PAPERCUP_IOS_SIM_UDID')
    device = next((d for d in devices if not selected or d['udid'] == selected), None)
    if not device:
        raise ValueError('An available iOS26 iPhone simulator is required (Intel hosts need the universal runtime)')
    env['PAPERCUP_IOS_SIM_UDID'] = device['udid']
    return {'xcode': xcode, 'iosSDK': sdk, 'simulator': device['udid'],
            'developerDir': env.get('DEVELOPER_DIR') or output(['xcode-select', '-p'], root, env)}


def ui_test(root, env, attempt, phases, name, tests):
    bundle = attempt / (name + '.xcresult')
    command = ['xcodebuild', 'test-without-building', '-project', 'ios/Papercup.xcodeproj',
               '-scheme', 'Papercup', '-destination', 'platform=iOS Simulator,id=' + env['PAPERCUP_IOS_SIM_UDID'],
               '-derivedDataPath', 'ios/build/dd', '-resultBundlePath', str(bundle)]
    command.extend('-only-testing:' + test for test in tests)
    run_phase(name, command, root, env, attempt, phases)
    summary = attempt / (name + '-summary.json')
    with summary.open('w') as stream:
        subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                        '--path', str(bundle), '--format', 'json'], cwd=root, env=env,
                       stdout=stream, check=True)
    run_phase(name + '-guard', ['python3', 'tools/build-scripts/check-xctest-summary.py',
                              str(summary), name], root, env, attempt, phases)
    result = json.loads(summary.read_text())
    if result['passedTests'] != len(tests):
        raise ValueError(name + ' must execute exactly the selected tests')
    attachments = attempt / (name + '-attachments')
    run_phase(name + '-screenshots', ['xcrun', 'xcresulttool', 'export', 'attachments',
                                    '--path', str(bundle), '--output-path', str(attachments)],
              root, env, attempt, phases)
    if not list(attachments.rglob('*.png')):
        raise ValueError(name + ' did not retain a candidate screenshot')


def artifacts(attempt):
    # Signing keys/keychains live in a separate TemporaryDirectory, never here.
    return [{'path': str(p.relative_to(attempt)), 'size': p.stat().st_size, 'sha256': digest(p)}
            for p in sorted(attempt.rglob('*')) if p.is_file() and p.name != 'result.json']


def release_manifest(attempt, result):
    """Extend the existing archive facts only after signed delivery admission."""
    path = attempt / 'candidate-manifest.json'
    manifest = json.loads(path.read_text())
    identity = result['source']
    if (identity['dirty'] or manifest.get('signed') is not True
            or manifest.get('sourceSha') != identity['commit']
            or manifest.get('build') != result['buildNumber']
            or not re.fullmatch(r'\d+\.\d+\.\d+', manifest.get('version', ''))):
        raise ValueError('Signed candidate manifest does not match admitted source/build')
    ipas = list((attempt / 'export').glob('*.ipa'))
    if len(ipas) != 1 or ipas[0].is_symlink() or not ipas[0].is_file():
        raise ValueError('Signed release requires exactly one retained regular IPA')
    ipa = ipas[0]
    manifest.update(schemaVersion=1, releaseVersion=manifest['version'],
                    sourceCommit=identity['commit'], sourceDirty=False,
                    builtAt=result['finishedAt'], artifacts=[{
                        'kind': 'ipa', 'path': str(ipa.relative_to(attempt)),
                        'size': ipa.stat().st_size, 'sha256': digest(ipa)}])
    write_json(path, manifest)


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
            if (result.get('executor') == 'native-mac' and result.get('mode') == 'check'
                    and Path(result['attempt']).resolve() == path.resolve()):
                shutil.rmtree(path)
        except (OSError, KeyError, ValueError):
            continue


def install_launch_agent(root, state):
    if platform.system() != 'Darwin':
        raise ValueError('Native launch agent installation requires macOS')
    template = plistlib.loads((root / 'tools/ci/com.papercusp.ios-ci.plist').read_bytes())
    template['ProgramArguments'] = [sys.executable, str(root / 'tools/ios-ci.py'), '--mode', 'check']
    template['WorkingDirectory'] = str(root)
    template['StandardOutPath'] = str(state / 'launcher.log')
    template['StandardErrorPath'] = str(state / 'launcher-error.log')
    template['EnvironmentVariables'] = {'PAPERCUP_IOS_CI_STATE': str(state)}
    if os.environ.get('DEVELOPER_DIR'):
        template['EnvironmentVariables']['DEVELOPER_DIR'] = os.environ['DEVELOPER_DIR']
    target = Path.home() / 'Library/LaunchAgents/com.papercusp.ios-ci.plist'
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix('.tmp')
    temporary.write_bytes(plistlib.dumps(template))
    temporary.chmod(0o600)
    temporary.replace(target)
    domain = 'gui/' + str(os.getuid())
    service = domain + '/' + template['Label']
    subprocess.run(['launchctl', 'bootout', service], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=False)
    subprocess.run(['launchctl', 'bootstrap', domain, str(target)], check=True)
    print('Native iPhone checks installed: ' + str(target))


def reuse(state, identity, tools, paired):
    try:
        proof = json.loads((state / 'success.json').read_text())
        attempt = Path(proof['attempt']).resolve()
        if (proof['status'] != 'passed' or proof['mode'] != 'check'
                or proof['source'] != identity or proof['toolchain'] != tools or proof['pairedUI'] != paired
                or proof['day'] != dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%d')
                or not attempt.is_relative_to((state / 'attempts').resolve())):
            return None
        required = {'release-contract', 'rust-pin', 'unit', 'ui-smoke', 'ui-smoke-guard',
                    'ui-smoke-screenshots', 'archive', 'archive-guard'}
        if required - {p['name'] for p in proof['phases'] if p['exitCode'] == 0} or not proof['artifacts']:
            return None
        for entry in proof['artifacts']:
            path = (attempt / entry['path']).resolve()
            if (not path.is_relative_to(attempt) or path.stat().st_size != entry['size']
                    or digest(path) != entry['sha256']):
                return None
        return proof
    except (OSError, KeyError, ValueError, TypeError):
        return None


def _execute(root, state, args):
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
    attempt = state / 'attempts' / stamp
    attempt.mkdir(parents=True)
    result = {'schemaVersion': 1, 'executor': 'native-mac', 'attempt': str(attempt),
              'startedAt': dt.datetime.now(dt.timezone.utc).isoformat(), 'status': 'failed',
              'mode': args.mode, 'pairedUI': args.paired_ui, 'phases': [],
              'day': dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%d')}
    env = os.environ.copy()
    env['PATH'] = str(Path.home() / '.cargo/bin') + ':/opt/homebrew/bin:/usr/local/bin:' + env.get('PATH', '/usr/bin:/bin:/usr/sbin:/sbin')
    env.pop('GITHUB_ENV', None)
    env.pop('TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD', None)
    env.pop('PAPERCUP_PAIR_PAYLOAD', None)
    if args.mode == 'check':
        for key in SIGNING_KEYS:
            env.pop(key, None)
    phases = result['phases']
    signing = None
    unit_started = False
    try:
        if args.upload and (args.mode != 'signed' or not args.confirm_upload):
            raise ValueError('Upload requires --mode signed --upload --confirm-upload')
        if args.mode == 'signed':
            if not args.build_number or not re.fullmatch(r'[1-9]\d*', args.build_number):
                raise ValueError('Signed delivery requires an explicit positive --build-number')
            load_signing(args.secrets_file, root, env)
        identity = source_identity(root)
        result['source'] = identity
        if args.mode == 'signed' and identity['dirty']:
            raise ValueError('Signed delivery requires clean committed source')
        result['toolchain'] = toolchain(root, env)
        env['PAPERCUP_IOS_SIM_UDID'] = result['toolchain']['simulator']
        run_phase('release-contract', ['bash', 'tools/build-scripts/verify-ios-release.sh', '--require-current-sdk'], root, env, attempt, phases)
        run_phase('rust-pin', ['make', 'test-rust-toolchain-pin'], root, env, attempt, phases)
        if args.preflight:
            result['status'] = 'preflight'
            return 0
        if args.mode == 'check' and not args.force and not args.paired_ui:
            cached = reuse(state, identity, result['toolchain'], False)
            if cached:
                write_json(state / 'latest.json', cached)
                result['status'] = 'reused'
                result['reusedAttempt'] = cached['attempt']
                return 0
        run_phase('rust-setup', ['rustup', 'toolchain', 'install'], root, env, attempt, phases)
        run_phase('ios-targets', ['rustup', 'target', 'add', 'aarch64-apple-ios', 'aarch64-apple-ios-sim', 'x86_64-apple-ios'], root, env, attempt, phases)
        pin = re.search(r'^channel\s*=\s*"([^"]+)"', (root / 'rust-toolchain.toml').read_text(), re.M)
        actual = output(['rustc', '--version'], root, env).split()[1]
        if not pin or actual != pin.group(1):
            raise ValueError('Effective Rust version does not match rust-toolchain.toml')
        run_phase('dependencies', ['npm', 'ci'], root, env, attempt, phases)
        run_phase('build', ['make', 'build-ios'], root, env, attempt, phases)
        # The result guard must see this attempt's evidence, never an old bundle.
        for path in (root / 'ios/build').glob('unit-*'):
            if path.is_dir():
                shutil.rmtree(path)
            elif path.is_file():
                path.unlink()
        unit_started = True
        run_phase('unit', ['make', 'test-ios'], root, env, attempt, phases)
        # Retain every unit attempt, including a failed destination-race attempt.
        for path in ((root / 'ios/build').glob('unit-*') if unit_started else ()):
            target = attempt / path.name
            if path.is_dir():
                shutil.copytree(path, target)
            elif path.is_file():
                shutil.copyfile(path, target)
        ui_test(root, env, attempt, phases, 'ui-smoke', SMOKE_TESTS)
        if args.paired_ui:
            if not args.pair_payload_file:
                raise ValueError('--paired-ui requires an owner-only --pair-payload-file')
            payload = private_input(args.pair_payload_file, root).read_text().strip()
            if not payload:
                raise ValueError('Paired UI input is empty')
            paired_env = dict(env, TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD=payload)
            ui_test(root, paired_env, attempt, phases, 'paired-ui',
                    ('PapercupUITests/PairFlowUITests/testPairAndPairedNavigation',))
        archive = attempt / 'Papercusp.xcarchive'
        if args.mode == 'signed':
            last = state / 'last-build-number.json'
            previous = json.loads(last.read_text())['buildNumber'] if last.exists() else 0
            if int(args.build_number) <= previous:
                raise ValueError('Build number was already reserved; choose a greater number')
            write_json(last, {'buildNumber': int(args.build_number), 'attempt': str(attempt)})
            result['buildNumber'] = args.build_number
            signing = tempfile.TemporaryDirectory(prefix='papercup-signing-')
            env['PAPERCUP_SIGNING_DIR'] = str(Path(signing.name) / 'material')
            env['PAPERCUP_SIGNING_ENV_FILE'] = str(Path(signing.name) / 'environment.json')
            run_phase('signing-install', ['bash', 'tools/build-scripts/ios-ci-signing.sh', 'install'], root, env, attempt, phases)
            env.update(json.loads(Path(env['PAPERCUP_SIGNING_ENV_FILE']).read_text()))
            env['PAPERCUP_BUILD_NUMBER'] = args.build_number
            env['PAPERCUP_RELEASE_DIR'] = str(attempt)
            run_phase('signed-export', ['bash', 'tools/build-scripts/release-ios.sh', 'export'], root, env, attempt, phases)
        else:
            run_phase('archive', ['xcodebuild', 'archive', '-project', 'ios/Papercup.xcodeproj',
                                 '-scheme', 'Papercup', '-configuration', 'Release',
                                 '-destination', 'generic/platform=iOS', '-archivePath', str(archive),
                                 'CODE_SIGNING_ALLOWED=NO'], root, env, attempt, phases)
        validation = ['python3', 'tools/build-scripts/validate-ios-archive.py', str(archive),
                      '--source-sha', identity['commit'], '--manifest', str(attempt / 'candidate-manifest.json')]
        if args.mode == 'signed':
            validation += ['--build', args.build_number, '--require-signed']
        run_phase('archive-guard', validation, root, env, attempt, phases)
        if source_identity(root) != identity:
            raise ValueError('Source changed during execution; candidate admission refused')
        if args.upload:
            ipas = list((attempt / 'export').glob('*.ipa'))
            if len(ipas) != 1:
                raise ValueError('Signed export must produce exactly one IPA')
            env['PAPERCUP_IPA_PATH'] = str(ipas[0])
            run_phase('testflight-upload', ['bash', 'tools/build-scripts/release-ios.sh', 'upload'], root, env, attempt, phases)
        result['status'] = 'passed'
        return 0
    except (Exception, KeyboardInterrupt) as error:
        result['error'] = str(error)
        print('iPhone CI refused: ' + str(error), file=sys.stderr)
        return 1
    finally:
        cleanup_failed = False
        if signing:
            try:
                run_phase('signing-cleanup', ['bash', 'tools/build-scripts/ios-ci-signing.sh', 'cleanup'], root, env, attempt, phases)
            except Exception as error:
                result['status'] = 'failed'
                result['error'] = 'Signing cleanup failed: ' + str(error)
                cleanup_failed = True
            signing.cleanup()
        # Keep real unit failures too, even when execution stopped before UI.
        for path in ((root / 'ios/build').glob('unit-*') if unit_started else ()):
            target = attempt / path.name
            if target.exists():
                continue
            if path.is_dir():
                shutil.copytree(path, target)
            elif path.is_file():
                shutil.copyfile(path, target)
        result['finishedAt'] = dt.datetime.now(dt.timezone.utc).isoformat()
        if result['status'] == 'passed' and args.mode == 'signed':
            try:
                release_manifest(attempt, result)
            except Exception as error:
                result['status'] = 'failed'
                result['error'] = str(error)
                cleanup_failed = True
        result['artifacts'] = artifacts(attempt)
        write_json(attempt / 'result.json', result)
        if result['status'] != 'reused':
            write_json(state / 'latest.json', result)
        if result['status'] == 'passed' and args.mode == 'check':
            write_json(state / 'success.json', result)
        elif result['status'] == 'failed':
            (state / 'success.json').unlink(missing_ok=True)
        prune_attempts(state)
        if cleanup_failed:
            raise SigningCleanupError(result['error'])


def execute(root, state, args):
    try:
        return _execute(root, state, args)
    except SigningCleanupError as error:
        print(str(error), file=sys.stderr)
        return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=('check', 'signed'), default='check')
    parser.add_argument('--preflight', action='store_true')
    parser.add_argument('--force', action='store_true')
    parser.add_argument('--paired-ui', action='store_true')
    parser.add_argument('--pair-payload-file')
    parser.add_argument('--build-number')
    parser.add_argument('--secrets-file')
    parser.add_argument('--upload', action='store_true')
    parser.add_argument('--confirm-upload', action='store_true')
    parser.add_argument('--install-launch-agent', action='store_true',
                        help='Install unsigned native checks every 30 minutes (macOS)')
    args = parser.parse_args()
    os.umask(0o077)
    state = Path(os.environ.get('PAPERCUP_IOS_CI_STATE', str(Path.home() / '.local/state/papercusp/ios-ci'))).resolve()
    if state.is_relative_to(ROOT):
        parser.error('CI state must be outside the source repository')
    state.mkdir(parents=True, exist_ok=True)
    state.chmod(0o700)
    with (state / 'executor.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('Native iPhone executor is already running; overlapping execution refused')
            return 1
        if args.install_launch_agent:
            install_launch_agent(ROOT, state)
            return 0
        return execute(ROOT, state, args)


if __name__ == '__main__':
    raise SystemExit(main())

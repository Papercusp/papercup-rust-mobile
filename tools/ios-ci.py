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
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True  # Importing shared CI must not change candidate source identity.
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
    'PapercupUITests/CloudWorkspaceOfflineUITests/testTransportFailureRecoversWithoutRepairing',
    'PapercupUITests/CloudWorkspaceOfflineUITests/testAuthorizationRefusalOffersPairAgainAndClearsKeychain',
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
            for key in ('TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD', 'TEST_RUNNER_PAPERCUP_EXPIRED_PAIR_PAYLOAD'):
                payload = env.get(key, '')
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
        required = set(SIGNING_KEYS if env.get('PAPERCUP_REQUIRE_UPLOAD_SECRETS', '1') == '1'
                       else SIGNING_KEYS[:4])
        if (not isinstance(values, dict) or not required <= set(values)
                or set(values) - set(SIGNING_KEYS)):
            raise ValueError('Signing JSON must contain the required signing inputs and no unknown keys')
        if any(not isinstance(v, str) or not v for v in values.values()):
            raise ValueError('Signing inputs must be nonempty strings')
        env.update(values)
    subprocess.run(['bash', 'tools/build-scripts/ios-ci-signing.sh', 'require-secrets'],
                   cwd=root, env=env, check=True)


def exported_profile(root, env, ipa):
    """Check the profile in the exported bytes, not just the archive's profile."""
    with zipfile.ZipFile(ipa) as archive:
        profiles = [name for name in archive.namelist()
                    if re.fullmatch(r'Payload/[^/]+\.app/embedded\.mobileprovision', name)]
        if len(profiles) != 1:
            raise ValueError('IPA must contain exactly one app provisioning profile')
        with tempfile.TemporaryDirectory(prefix='papercup-export-profile-') as directory:
            profile = Path(directory) / 'embedded.mobileprovision'
            profile.write_bytes(archive.read(profiles[0]))
            profile.chmod(0o600)
            facts = json.loads(output(['bash', 'tools/build-scripts/ios-ci-signing.sh',
                                      'check-profile', str(profile), env['APPLE_TEAM_ID'],
                                      '--json'], root, env))
    if env['PAPERCUP_SIGNING_CERT_SHA1'] not in facts['certificateSha1s']:
        raise ValueError('Exported profile does not include the installed distribution identity')
    return {'distributionMethod': env['PAPERCUP_EXPORT_METHOD'],
            'registeredDeviceCount': facts['registeredDeviceCount'],
            'profileExpiresAt': facts['expiresAt'],
            'installationRoute': ('registered-device' if env['PAPERCUP_EXPORT_METHOD'] == 'release-testing'
                                  else 'app-store-connect')}


def toolchain(root, env, mode='check'):
    if platform.system() != 'Darwin':
        raise ValueError('Native iPhone execution requires macOS')
    if mode not in ('simulator', 'check', 'signed'):
        raise ValueError('Unsupported native iPhone mode')
    simulator_only = mode == 'simulator'
    names = ('git', 'make', 'node', 'python3', 'rustup', 'rustc',
             'xcrun', 'xcodebuild', 'xcodegen')
    if mode == 'signed':
        names += ('security',)
    missing = [name for name in names if not shutil.which(name, path=env['PATH'])]
    if missing:
        raise ValueError('Missing native iPhone tools: ' + ', '.join(missing))
    sdk_name = 'iphonesimulator' if simulator_only else 'iphoneos'
    sdk = output(['xcrun', '--sdk', sdk_name, '--show-sdk-version'], root, env)
    minimum = 17 if simulator_only else 26
    if not re.fullmatch(r'\d+(?:\.\d+)*', sdk) or int(sdk.split('.')[0]) < minimum:
        label = 'iPhoneSimulator SDK17+' if simulator_only else 'iPhoneOS SDK26+'
        raise ValueError(label + ' is required; found ' + sdk)
    xcode = output(['xcodebuild', '-version'], root, env)
    version = re.match(r'Xcode (\d+)\.(\d+)', xcode)
    required = (16, 3) if simulator_only else (26, 0)
    if not version or tuple(map(int, version.groups())) < required:
        label = 'Xcode16.3+' if simulator_only else 'Xcode26+'
        raise ValueError(label + ' is required; found ' + xcode)
    sims = json.loads(output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], root, env))
    devices = []
    for runtime, rows in sims['devices'].items():
        version = re.fullmatch(r'com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+)((?:-\d+)*)', runtime)
        if not version or int(version.group(1)) < minimum:
            continue
        runtime_version = tuple(map(int, (version.group(1) + version.group(2)).split('-')))
        for device in rows:
            if device.get('isAvailable') and device.get('name', '').startswith('iPhone'):
                devices.append((runtime_version, runtime, device))
    devices.sort(key=lambda row: row[0], reverse=True)
    selected = env.get('PAPERCUP_IOS_SIM_UDID')
    choice = next((row for row in devices if not selected or row[2]['udid'] == selected), None)
    if not choice:
        label = 'iOS17+' if simulator_only else 'iOS26+'
        raise ValueError('An available ' + label + ' iPhone simulator is required (Intel hosts need the universal runtime)')
    _, runtime, device = choice
    env['PAPERCUP_IOS_SIM_UDID'] = device['udid']
    return {'xcode': xcode, 'simulatorSDK' if simulator_only else 'iosSDK': sdk,
            'simulatorRuntime': runtime, 'simulator': device['udid'],
            'developerDir': env.get('DEVELOPER_DIR') or output(['xcode-select', '-p'], root, env)}


def ui_test(root, env, attempt, phases, name, tests, shared_simulator=False):
    bundle = attempt / (name + '.xcresult')
    command = ['xcodebuild', 'test-without-building', '-project', 'ios/Papercup.xcodeproj',
               '-scheme', 'Papercup', '-destination', 'platform=iOS Simulator,id=' + env['PAPERCUP_IOS_SIM_UDID'],
               '-derivedDataPath', 'ios/build/dd', '-resultBundlePath', str(bundle)]
    if shared_simulator:
        # simctl uninstall must target the same device that executed the UI test,
        # not an Xcode-created parallel-test clone.
        command.extend(['-parallel-testing-enabled', 'NO'])
    command.extend('-only-testing:' + test for test in tests)
    test_error = None
    try:
        run_phase(name, command, root, env, attempt, phases)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        test_error = error
    # A failed XCTest is exactly when its native summary and attachments are
    # needed. Collect both before returning the original execution failure.
    diagnostic_errors = []
    summary = attempt / (name + '-summary.json')
    try:
        with summary.open('w') as stream:
            subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                            '--path', str(bundle), '--format', 'json'], cwd=root, env=env,
                           stdout=stream, check=True)
        run_phase(name + '-guard', ['python3', 'tools/build-scripts/check-xctest-summary.py',
                                  str(summary), name], root, env, attempt, phases)
        result = json.loads(summary.read_text())
        if result['passedTests'] != len(tests):
            raise ValueError(name + ' must execute exactly the selected tests')
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        diagnostic_errors.append(('summary', error))
    attachments = attempt / (name + '-attachments')
    try:
        run_phase(name + '-screenshots', ['xcrun', 'xcresulttool', 'export', 'attachments',
                                        '--path', str(bundle), '--output-path', str(attachments)],
                  root, env, attempt, phases)
        if not list(attachments.rglob('*.png')):
            raise ValueError(name + ' did not retain a candidate screenshot')
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        diagnostic_errors.append(('attachments', error))
    if diagnostic_errors:
        # Retain secondary failures without allowing their messages to echo
        # private test inputs or conceal the original XCTest verdict.
        (attempt / (name + '-diagnostic-errors.json')).write_text(json.dumps([
            {'stage': stage, 'errorType': type(error).__name__}
            for stage, error in diagnostic_errors], indent=2) + '\n')
    if test_error:
        raise test_error
    if diagnostic_errors:
        raise diagnostic_errors[0][1]


def reinstall_ui(root, env, attempt, phases):
    """Exercise OS uninstall/reinstall between native positive and negative controls."""
    bundle_id = 'com.papercuspai.operator.mobile'
    app = root / 'ios/build/dd/Build/Products/Debug-iphonesimulator/Papercup.app'
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != bundle_id:
        raise ValueError('Reinstall requires the built Papercup simulator app')
    ui_test(root, env, attempt, phases, 'reinstall-pair',
            ('PapercupUITests/PairFlowUITests/testPairBeforeActualReinstall',), True)
    # Only the first test receives the one-shot pairing token. Subsequent
    # launches must use persisted Keychain credentials or fresh-install reset.
    ordinary_env = dict(env)
    ordinary_env.pop('TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD', None)
    ordinary_env['TEST_RUNNER_PAPERCUP_REINSTALL_PHASE'] = 'before-uninstall'
    ui_test(root, ordinary_env, attempt, phases, 'reinstall-relaunch',
            ('PapercupUITests/PairFlowUITests/testAuthorizedRelaunchBeforeActualReinstall',), True)
    simulator = env['PAPERCUP_IOS_SIM_UDID']
    original_data = Path(output(['xcrun', 'simctl', 'get_app_container', simulator,
                                 bundle_id, 'data'], root, env))
    if not original_data.is_absolute() or not original_data.is_dir():
        raise ValueError('Installed app must have an existing simulator data container')
    run_phase('reinstall-uninstall', ['xcrun', 'simctl', 'uninstall', simulator, bundle_id],
              root, ordinary_env, attempt, phases)
    absent = subprocess.run(['xcrun', 'simctl', 'get_app_container', simulator, bundle_id, 'data'],
                            cwd=root, env=ordinary_env, capture_output=True, text=True)
    if absent.returncode == 0 or original_data.exists():
        raise ValueError('Uninstall did not remove the installed app and its data container')
    run_phase('reinstall-install', ['xcrun', 'simctl', 'install', simulator, str(app)],
              root, ordinary_env, attempt, phases)
    installed_data = Path(output(['xcrun', 'simctl', 'get_app_container', simulator,
                                  bundle_id, 'data'], root, env))
    if not installed_data.is_dir() or installed_data == original_data:
        raise ValueError('Reinstall must create a different app data container')
    ordinary_env['TEST_RUNNER_PAPERCUP_REINSTALL_PHASE'] = 'after-uninstall'
    ui_test(root, ordinary_env, attempt, phases, 'reinstall-onboarding',
            ('PapercupUITests/PairFlowUITests/testActualReinstallClearsOldPairing',), True)
    write_json(attempt / 'reinstall.json', {
        'schemaVersion': 1, 'bundleId': bundle_id, 'simulator': simulator,
        'originalDataContainer': str(original_data), 'uninstallVerified': True,
        'installedDataContainer': str(installed_data), 'newDataContainerVerified': True,
        'ordinaryRelaunchAuthorized': True, 'reinstalledOnboardingVerified': True})


def prepare_derived_data(root, tools):
    """Compiled Xcode state is bound to its absolute checkout and toolchain."""
    directory = root / 'ios/build/dd'
    if directory.is_symlink():
        raise ValueError('Native DerivedData must not be a symlink')
    owner = {'schemaVersion': 1, 'checkout': str(root.resolve()),
             'derivedData': str(directory.resolve()),
             'toolchain': {key: tools.get(key) for key in
                           ('xcode', 'developerDir', 'iosSDK', 'simulatorSDK')}}
    marker = directory / 'papercup-native-owner.json'
    try:
        previous = json.loads(marker.read_text())
    except (OSError, ValueError):
        previous = None
    reset = previous != owner
    removed = []
    if reset and directory.exists():
        # SwiftPM downloads can be reused after a copy. PCH/module caches,
        # build databases and products embed absolute paths and cannot.
        for path in directory.iterdir():
            if path.name == 'SourcePackages' and not path.is_symlink():
                continue
            removed.append(path.name)
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()
    directory.mkdir(parents=True, exist_ok=True)
    write_json(marker, owner)
    return {'owner': owner, 'previousOwner': previous, 'reset': reset,
            'removed': sorted(removed)}


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
                    builtAt=result['finishedAt'], installation=result['installation'], artifacts=[{
                        'kind': 'ipa', 'path': str(ipa.relative_to(attempt)),
                        'size': ipa.stat().st_size, 'sha256': digest(ipa)}])
    write_json(path, manifest)


def success_path(state, mode):
    return state / ('success-simulator.json' if mode == 'simulator' else 'success.json')


def prune_attempts(state, keep=16):
    protected = set()
    for name in ('latest.json', 'success.json', 'success-simulator.json'):
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
            if (result.get('executor') == 'native-mac' and result.get('mode') in ('simulator', 'check')
                    and Path(result['attempt']).resolve() == path.resolve()):
                shutil.rmtree(path)
        except (OSError, KeyError, ValueError):
            continue


def install_launch_agent(root, state):
    if platform.system() != 'Darwin':
        raise ValueError('Native launch agent installation requires macOS')
    env = os.environ.copy()
    env['PATH'] = str(Path.home() / '.cargo/bin') + ':/opt/homebrew/bin:/usr/local/bin:' + env.get('PATH', '/usr/bin:/bin:/usr/sbin:/sbin')
    # Refuse before installing a recurring job that cannot execute on this Mac.
    toolchain(root, env, 'simulator')
    template = plistlib.loads((root / 'tools/ci/com.papercusp.ios-ci.plist').read_bytes())
    template['ProgramArguments'] = [sys.executable, str(root / 'tools/ios-ci.py'), '--mode', 'simulator']
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


def reuse(state, identity, tools, paired, mode='check'):
    try:
        proof = json.loads(success_path(state, mode).read_text())
        attempt = Path(proof['attempt']).resolve()
        if (proof['status'] != 'passed' or proof['mode'] != mode
                or proof['source'] != identity or proof['toolchain'] != tools or proof['pairedUI'] != paired
                or proof['day'] != dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%d')
                or not attempt.is_relative_to((state / 'attempts').resolve())):
            return None
        required = {'release-contract', 'rust-pin', 'rust-setup', 'ios-targets',
                    'dependencies', 'dependency-audit', 'build', 'unit', 'ui-smoke', 'ui-smoke-guard',
                    'ui-smoke-screenshots'}
        if mode == 'check':
            required |= {'archive', 'archive-guard'}
        elif mode != 'simulator':
            return None
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
              'mode': args.mode, 'distributionMethod': args.distribution,
              'pairedUI': args.paired_ui or args.reinstall_ui,
              'reinstallUI': args.reinstall_ui, 'phases': [],
              'day': dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%d')}
    env = os.environ.copy()
    env['PATH'] = str(Path.home() / '.cargo/bin') + ':/opt/homebrew/bin:/usr/local/bin:' + env.get('PATH', '/usr/bin:/bin:/usr/sbin:/sbin')
    env.pop('GITHUB_ENV', None)
    env.pop('TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD', None)
    env.pop('PAPERCUP_PAIR_PAYLOAD', None)
    env.pop('TEST_RUNNER_PAPERCUP_EXPIRED_PAIR_PAYLOAD', None)
    env.pop('PAPERCUP_EXPIRED_PAIR_PAYLOAD', None)
    env['PAPERCUP_EXPORT_METHOD'] = args.distribution
    env['PAPERCUP_REQUIRE_UPLOAD_SECRETS'] = '1' if args.upload else '0'
    if args.mode != 'signed':
        for key in SIGNING_KEYS:
            env.pop(key, None)
    phases = result['phases']
    signing = None
    unit_started = False
    try:
        if args.upload and (args.mode != 'signed' or not args.confirm_upload):
            raise ValueError('Upload requires --mode signed --upload --confirm-upload')
        if args.distribution not in ('app-store-connect', 'release-testing'):
            raise ValueError('Unsupported iPhone distribution method')
        if args.upload and args.distribution != 'app-store-connect':
            raise ValueError('Registered-device IPA export cannot be uploaded to App Store Connect')
        paired_env = None
        offline_recovery = getattr(args, 'offline_recovery_ui', False)
        workspace_switch = getattr(args, 'workspace_switch_ui', False)
        if workspace_switch and (not args.paired_ui or args.mode != 'simulator'
                                 or args.expired_pair_payload_file or args.reinstall_ui or offline_recovery):
            raise ValueError('--workspace-switch-ui requires simulator --paired-ui and a separate one-shot token')
        if offline_recovery and (not args.paired_ui or args.mode != 'simulator'
                                 or args.expired_pair_payload_file or args.reinstall_ui):
            raise ValueError('--offline-recovery-ui requires simulator --paired-ui and a separate one-shot token')
        if args.expired_pair_payload_file and not args.paired_ui:
            raise ValueError('--expired-pair-payload-file requires --paired-ui')
        if args.reinstall_ui and (args.paired_ui or args.mode != 'simulator'):
            raise ValueError('--reinstall-ui requires simulator mode and cannot share a one-shot token with --paired-ui')
        if args.paired_ui or args.reinstall_ui:
            if not args.pair_payload_file:
                raise ValueError('Live UI requires an owner-only --pair-payload-file')
            payload = private_input(args.pair_payload_file, root).read_text().strip()
            if not payload or not isinstance(json.loads(payload), dict) or not json.loads(payload):
                raise ValueError('Paired UI input must be a nonempty JSON object')
            paired_env = dict(env, TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD=payload)
            if args.expired_pair_payload_file:
                expired = private_input(args.expired_pair_payload_file, root).read_text().strip()
                fresh_data, expired_data = json.loads(payload), json.loads(expired)
                if (not isinstance(expired_data, dict)
                        or not all(isinstance(expired_data.get(k), str) and expired_data[k]
                                   for k in ('server', 'workspaceId', 'pairToken'))
                        or any(expired_data[k] != fresh_data.get(k) for k in ('server', 'workspaceId'))
                        or expired_data['pairToken'] == fresh_data.get('pairToken')):
                    raise ValueError('Expiry UI requires a distinct token for the same owned endpoint/workspace')
                paired_env['TEST_RUNNER_PAPERCUP_EXPIRED_PAIR_PAYLOAD'] = expired
        if args.mode == 'signed':
            if not args.build_number or not re.fullmatch(r'[1-9]\d*', args.build_number):
                raise ValueError('Signed delivery requires an explicit positive --build-number')
            load_signing(args.secrets_file, root, env)
        identity = source_identity(root)
        result['source'] = identity
        if args.mode == 'signed' and identity['dirty']:
            raise ValueError('Signed delivery requires clean committed source')
        result['toolchain'] = toolchain(root, env, args.mode)
        env['PAPERCUP_IOS_SIM_UDID'] = result['toolchain']['simulator']
        contract = ['bash', 'tools/build-scripts/verify-ios-release.sh']
        if args.mode != 'simulator':
            contract.append('--require-current-sdk')
        run_phase('release-contract', contract, root, env, attempt, phases)
        run_phase('rust-pin', ['make', 'test-rust-toolchain-pin'], root, env, attempt, phases)
        if args.preflight:
            result['status'] = 'preflight'
            return 0
        # Recheck the locked dependency graph before both execution and reuse:
        # advisory data can change without a source or lockfile change.
        run_phase('dependency-audit', ['npm', 'audit', '--package-lock-only',
                                     '--audit-level=moderate'], root, env, attempt, phases)
        if args.mode in ('simulator', 'check') and not args.force and not (args.paired_ui or args.reinstall_ui):
            cached = reuse(state, identity, result['toolchain'], False, args.mode)
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
        write_json(attempt / 'derived-data.json',
                   prepare_derived_data(root, result['toolchain']))
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
            paired_env.update(env)
            paired_case = ('testOwnedWorkspaceSwitchAndKeychainRelaunch' if workspace_switch else
                           'testOwnedOperatorOfflineThenRecoversWithoutRepairing' if offline_recovery else
                           'testPublicExpiredPairThenFreshPair' if args.expired_pair_payload_file else
                           'testPairAndPairedNavigation')
            ui_test(root, paired_env, attempt, phases, 'paired-ui',
                    ('PapercupUITests/PairFlowUITests/' + paired_case,))
        if args.reinstall_ui:
            paired_env.update(env)
            reinstall_ui(root, paired_env, attempt, phases)
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
        elif args.mode == 'check':
            run_phase('archive', ['xcodebuild', 'archive', '-project', 'ios/Papercup.xcodeproj',
                                 '-scheme', 'Papercup', '-configuration', 'Release',
                                 '-destination', 'generic/platform=iOS', '-archivePath', str(archive),
                                 'CODE_SIGNING_ALLOWED=NO'], root, env, attempt, phases)
        if args.mode != 'simulator':
            validation = ['python3', 'tools/build-scripts/validate-ios-archive.py', str(archive),
                          '--source-sha', identity['commit'], '--manifest', str(attempt / 'candidate-manifest.json')]
            if args.mode == 'signed':
                validation += ['--build', args.build_number, '--require-signed']
            run_phase('archive-guard', validation, root, env, attempt, phases)
        if source_identity(root) != identity:
            raise ValueError('Source changed during execution; candidate admission refused')
        if args.mode == 'signed':
            ipas = list((attempt / 'export').glob('*.ipa'))
            if len(ipas) != 1 or ipas[0].is_symlink() or not ipas[0].is_file():
                raise ValueError('Signed export must produce exactly one regular IPA')
            result['installation'] = exported_profile(root, env, ipas[0])
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
        if result['status'] == 'passed' and args.mode in ('simulator', 'check'):
            write_json(success_path(state, args.mode), result)
        elif result['status'] == 'failed':
            success_path(state, args.mode).unlink(missing_ok=True)
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
    parser.add_argument('--mode', choices=('simulator', 'check', 'signed'), default='simulator',
                        help='simulator runs native tests; check adds SDK26 unsigned archive; signed exports IPA')
    parser.add_argument('--distribution', choices=('app-store-connect', 'release-testing'),
                        default='app-store-connect',
                        help='release-testing exports an Ad Hoc IPA for registered devices')
    parser.add_argument('--preflight', action='store_true')
    parser.add_argument('--force', action='store_true')
    parser.add_argument('--paired-ui', action='store_true')
    parser.add_argument('--workspace-switch-ui', action='store_true',
                        help='With simulator --paired-ui, verify distinct owned workspaces and persisted switching')
    parser.add_argument('--offline-recovery-ui', action='store_true',
                        help='With simulator --paired-ui, verify the owned fixture operator stops and recovers')
    parser.add_argument('--reinstall-ui', action='store_true',
                        help='Pair, prove ordinary relaunch, uninstall/reinstall and verify cleared pairing')
    parser.add_argument('--pair-payload-file')
    parser.add_argument('--expired-pair-payload-file',
                        help='With --paired-ui, exercise real expired-code guidance then fresh pairing')
    parser.add_argument('--build-number')
    parser.add_argument('--secrets-file')
    parser.add_argument('--upload', action='store_true')
    parser.add_argument('--confirm-upload', action='store_true')
    parser.add_argument('--install-launch-agent', action='store_true',
                        help='Install simulator native checks every 30 minutes (macOS)')
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

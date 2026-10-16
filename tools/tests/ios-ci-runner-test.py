#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Behavioral acceptance of native CI admission, retained evidence and delivery."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('ios_ci', ROOT / 'tools/ios-ci.py')
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class NativeRunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.root = self.base / 'repo'
        self.root.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        (self.root / 'rust-toolchain.toml').write_text('[toolchain]\nchannel = "1.99.0"\n')
        self.state = self.base / 'state'
        self.state.mkdir()
        self.identity = {'commit': 'a' * 40, 'fingerprint': 'b' * 64, 'dirty': False}
        self.native = {'xcode': 'Xcode 26.6', 'iosSDK': '26.5', 'simulator': 'SIM', 'developerDir': '/Xcode'}
        self.calls = []
        self.commands = {}
        self.failure_phase = None
        self.counts = {'passedTests': len(ci.SMOKE_TESTS), 'failedTests': 0, 'skippedTests': 0}
        self.args = argparse.Namespace(mode='check', distribution='app-store-connect', preflight=False, force=False,
                                       paired_ui=False, reinstall_ui=False, offline_recovery_ui=False,
                                       workspace_switch_ui=False, device_expiry_ui=False, pair_payload_file=None,
                                       expired_pair_payload_file=None,
                                       build_number=None, secrets_file=None,
                                       upload=False, confirm_upload=False)

    def phase(self, name, command, root, env, attempt, phases):
        self.calls.append(name)
        self.commands[name] = (command, dict(env))
        log = attempt / (name + '.log')
        log.write_text(name + '\n')
        phases.append({'name': name, 'exitCode': int(name == self.failure_phase), 'log': str(log)})
        if name == self.failure_phase:
            raise RuntimeError('fixture failure: ' + name)
        if name in ('archive', 'signed-export'):
            (attempt / 'Papercusp.xcarchive').mkdir()
        if name == 'signed-export':
            (attempt / 'export').mkdir()
            with zipfile.ZipFile(attempt / 'export/app.ipa', 'w') as ipa:
                ipa.writestr('Payload/Papercup.app/embedded.mobileprovision', b'fixture profile')
        if name == 'signing-install':
            Path(env['PAPERCUP_SIGNING_ENV_FILE']).write_text(json.dumps({
                'APPLE_TEAM_ID': 'ABCDE12345', 'PAPERCUP_SIGNING_CERT_SHA1': 'C' * 40}))
        if name == 'archive-guard':
            (attempt / 'candidate-manifest.json').write_text(json.dumps({
                'sourceSha': self.identity['commit'], 'version': '1.0.0',
                'build': self.args.build_number or '1', 'signed': self.args.mode == 'signed'}))
        if name.endswith('-guard') and name != 'archive-guard':
            # Exercise the maintained result classifier with a real subprocess.
            subprocess.run(['python3', str(ROOT / 'tools/build-scripts/check-xctest-summary.py'),
                            command[-2], name], check=True)
        if name.endswith('-screenshots'):
            directory = Path(command[-1])
            directory.mkdir()
            (directory / 'candidate.png').write_bytes(b'fixture png')

    def summary(self, command, **kwargs):
        kwargs['stdout'].write(json.dumps(self.counts))
        return subprocess.CompletedProcess(command, 0)

    def run_ci(self, identities=None):
        real_run = subprocess.run

        def native_run(command, **kwargs):
            if command[0] == 'xcrun':
                return self.summary(command, **kwargs)
            return real_run(command, **kwargs)

        with patch.object(ci, 'source_identity', side_effect=identities or [self.identity, self.identity]), \
                patch.object(ci, 'toolchain', return_value=self.native), \
                patch.object(ci, 'output', side_effect=lambda command, *unused: (
                    json.dumps({'registeredDeviceCount': 2 if self.args.distribution == 'release-testing' else 0,
                                'expiresAt': '2030-01-01T00:00:00+00:00', 'certificateSha1s': ['C' * 40]})
                    if command[0] == 'bash' else 'rustc 1.99.0')), \
                patch.object(ci, 'run_phase', side_effect=self.phase), \
                patch.object(ci, 'load_signing'), \
                patch.object(ci.subprocess, 'run', side_effect=native_run):
            return ci.execute(self.root, self.state, self.args)

    def latest(self):
        return json.loads((self.state / 'latest.json').read_text())

    def test_expiry_ui_admission_and_selected_case(self):
        self.args.mode = 'simulator'
        self.args.paired_ui = True
        fresh = {'server': 'https://native-iphone-test.example.org',
                 'workspaceId': 'test-runtime-native-test', 'pairToken': 'fresh-private-token'}
        pair_path, expired_path = self.base / 'fresh.json', self.base / 'expired.json'
        pair_path.write_text(json.dumps(fresh))
        pair_path.chmod(0o600)
        expired_path.write_text(json.dumps(dict(fresh, pairToken='expired-private-token')))
        expired_path.chmod(0o600)
        self.args.pair_payload_file = str(pair_path)
        self.args.expired_pair_payload_file = str(expired_path)
        original_summary = self.summary
        def summary(command, **kwargs):
            if 'paired-ui.xcresult' in ' '.join(command):
                kwargs['stdout'].write(json.dumps({'passedTests': 1, 'failedTests': 0, 'skippedTests': 0}))
                return subprocess.CompletedProcess(command, 0)
            return original_summary(command, **kwargs)
        self.summary = summary
        self.assertEqual(self.run_ci(), 0)
        command, env = self.commands['paired-ui']
        self.assertIn('-only-testing:PapercupUITests/PairFlowUITests/testPublicExpiredPairThenFreshPair', command)
        self.assertIn('expired-private-token', env['TEST_RUNNER_PAPERCUP_EXPIRED_PAIR_PAYLOAD'])
        self.assertNotIn('TEST_RUNNER_PAPERCUP_EXPIRED_PAIR_PAYLOAD', self.commands['unit'][1])
        self.calls.clear()
        expired_path.write_text(json.dumps(fresh))
        self.assertEqual(self.run_ci(), 1)
        self.assertNotIn('build', self.calls)
        self.assertIn('distinct token', self.latest()['error'])
        self.args.paired_ui = False
        self.assertEqual(self.run_ci(), 1)
        self.assertIn('requires --paired-ui', self.latest()['error'])

    def test_owned_operator_recovery_selects_only_its_fresh_token_case(self):
        self.args.mode = 'simulator'
        self.args.paired_ui = True
        self.args.offline_recovery_ui = True
        pair_path = self.base / 'fresh.json'
        pair_path.write_text(json.dumps({'server': 'https://native-iphone-test.example.org',
                                        'workspaceId': 'test-runtime-native-test', 'pairToken': 'private-token'}))
        pair_path.chmod(0o600)
        self.args.pair_payload_file = str(pair_path)
        original_summary = self.summary
        def summary(command, **kwargs):
            if 'paired-ui.xcresult' in ' '.join(command):
                kwargs['stdout'].write(json.dumps({'passedTests': 1, 'failedTests': 0, 'skippedTests': 0}))
                return subprocess.CompletedProcess(command, 0)
            return original_summary(command, **kwargs)
        self.summary = summary
        self.assertEqual(self.run_ci(), 0)
        command, env = self.commands['paired-ui']
        self.assertIn('-only-testing:PapercupUITests/PairFlowUITests/testOwnedOperatorOfflineThenRecoversWithoutRepairing', command)
        self.assertNotIn('TEST_RUNNER_PAPERCUP_EXPIRED_PAIR_PAYLOAD', env)
        for changes in ({'paired_ui': False}, {'mode': 'signed'},
                        {'expired_pair_payload_file': str(pair_path)}, {'reinstall_ui': True}):
            self.calls.clear()
            with patch.multiple(self.args, **changes):
                self.assertEqual(self.run_ci(), 1)
                self.assertNotIn('build', self.calls)
                self.assertIn('--offline-recovery-ui requires', self.latest()['error'])

    def test_workspace_switch_selects_its_case_and_refuses_shared_token_journeys(self):
        self.args.mode = 'simulator'
        self.args.paired_ui = True
        self.args.workspace_switch_ui = True
        pair_path = self.base / 'fresh.json'
        pair_path.write_text(json.dumps({'server': 'https://native-iphone-test.example.org',
                                        'workspaceId': 'test-runtime-native-test', 'pairToken': 'private-token'}))
        pair_path.chmod(0o600)
        self.args.pair_payload_file = str(pair_path)
        original_summary = self.summary
        def summary(command, **kwargs):
            if 'paired-ui.xcresult' in ' '.join(command):
                kwargs['stdout'].write(json.dumps({'passedTests': 1, 'failedTests': 0, 'skippedTests': 0}))
                return subprocess.CompletedProcess(command, 0)
            return original_summary(command, **kwargs)
        self.summary = summary
        self.assertEqual(self.run_ci(), 0)
        command, env = self.commands['paired-ui']
        self.assertIn('-only-testing:PapercupUITests/PairFlowUITests/testOwnedWorkspaceSwitchAndKeychainRelaunch', command)
        self.assertNotIn('TEST_RUNNER_PAPERCUP_EXPIRED_PAIR_PAYLOAD', env)
        self.assertNotIn('TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD', self.commands['unit'][1])
        for changes in ({'paired_ui': False}, {'mode': 'signed'}, {'offline_recovery_ui': True},
                        {'expired_pair_payload_file': str(pair_path)}, {'reinstall_ui': True}):
            self.calls.clear()
            with patch.multiple(self.args, **changes):
                self.assertEqual(self.run_ci(), 1)
                self.assertNotIn('build', self.calls)
                self.assertIn('--workspace-switch-ui requires', self.latest()['error'])

    def test_device_expiry_selects_its_case_and_rejects_public_or_shared_journeys(self):
        self.args.mode = 'simulator'
        self.args.paired_ui = True
        self.args.device_expiry_ui = True
        pair_path = self.base / 'fresh.json'
        payload = {'server': 'http://127.0.0.1:48991',
                   'workspaceId': 'test-runtime-native-test', 'pairToken': 'private-device-expiry-token'}
        pair_path.write_text(json.dumps(payload))
        pair_path.chmod(0o600)
        self.args.pair_payload_file = str(pair_path)
        original_summary = self.summary
        def summary(command, **kwargs):
            if 'paired-ui.xcresult' in ' '.join(command):
                kwargs['stdout'].write(json.dumps({'passedTests': 1, 'failedTests': 0, 'skippedTests': 0}))
                return subprocess.CompletedProcess(command, 0)
            return original_summary(command, **kwargs)
        self.summary = summary
        self.assertEqual(self.run_ci(), 0)
        self.assertIn('-only-testing:PapercupUITests/PairFlowUITests/testLiveDeviceExpiryAndRepairing',
                      self.commands['paired-ui'][0])
        self.assertNotIn('TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD', self.commands['unit'][1])
        for changes in ({'paired_ui': False}, {'mode': 'signed'}, {'offline_recovery_ui': True},
                        {'workspace_switch_ui': True}, {'expired_pair_payload_file': str(pair_path)},
                        {'reinstall_ui': True}):
            with patch.multiple(self.args, **changes):
                self.calls.clear()
                self.assertEqual(self.run_ci(), 1)
                self.assertNotIn('build', self.calls)
                self.assertIn('--device-expiry-ui requires', self.latest()['error'])
        for change in ({'server': 'https://public.example.org'}, {'workspaceId': 'production'},
                       {'server': 'http://127.0.0.1:3070'}, {'server': 'http://127.0.0.1:3170'},
                       {'server': 'http://127.0.0.1:48991/admin'}, {'server': 'http://127.0.0.1:48991/?x=y'},
                       {'server': 'http://private@127.0.0.1:48991'}, {'pairToken': ''}):
            pair_path.write_text(json.dumps(dict(payload, **change)))
            self.calls.clear()
            self.assertEqual(self.run_ci(), 1)
            self.assertNotIn('build', self.calls)
            self.assertIn('owned private loopback', self.latest()['error'])

    def test_simulator_pass_keeps_test_proof_without_archive_or_signing(self):
        self.args.mode = 'simulator'
        with patch.dict(os.environ, {key: 'private-fixture' for key in ci.SIGNING_KEYS}):
            self.assertEqual(self.run_ci(), 0)
        result = self.latest()
        self.assertEqual(result['mode'], 'simulator')
        self.assertEqual(result['status'], 'passed')
        names = {a['path'] for a in result['artifacts']}
        self.assertIn('ui-smoke-summary.json', names)
        self.assertIn('ui-smoke-attachments/candidate.png', names)
        self.assertNotIn('candidate-manifest.json', names)
        self.assertNotIn('archive', self.calls)
        self.assertNotIn('archive-guard', self.calls)
        self.assertNotIn('signing-install', self.calls)
        contract, env = self.commands['release-contract']
        self.assertNotIn('--require-current-sdk', contract)
        self.assertFalse(set(ci.SIGNING_KEYS) & set(env))
        self.assertTrue((self.state / 'success-simulator.json').exists())
        self.assertFalse((self.state / 'success.json').exists())

    def test_simulator_cache_cannot_satisfy_release_checks(self):
        self.args.mode = 'simulator'
        self.assertEqual(self.run_ci(), 0)
        proof = self.latest()
        self.assertIsNotNone(ci.reuse(self.state, self.identity, self.native, False, 'simulator'))
        self.assertIsNone(ci.reuse(self.state, self.identity, self.native, False))
        self.calls.clear()
        self.assertEqual(self.run_ci(), 0)
        self.assertNotIn('build', self.calls)
        self.assertEqual(self.latest()['attempt'], proof['attempt'])
        self.args.mode = 'check'
        self.assertEqual(self.run_ci(), 0)
        self.assertIn('archive', self.calls)
        self.assertIn('--require-current-sdk', self.commands['release-contract'][0])
        self.assertTrue((self.state / 'success.json').exists())
        self.assertTrue((self.state / 'success-simulator.json').exists())

    def test_old_three_test_summary_cannot_admit_recovery_coverage(self):
        self.args.mode = 'simulator'
        self.counts = {'passedTests': 3, 'failedTests': 0, 'skippedTests': 0}
        self.assertEqual(self.run_ci(), 1)
        self.assertEqual(self.latest()['status'], 'failed')
        self.assertFalse((self.state / 'success-simulator.json').exists())

    def test_copied_derived_data_rebuilds_compiled_state_and_keeps_packages(self):
        ci.prepare_derived_data(self.root, self.native)
        directory = self.root / 'ios/build/dd'
        for name in ('ModuleCache.noindex/old.pch', 'Build/old.o',
                     'SourcePackages/checkouts/package/source.swift'):
            path = directory / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('old checkout')
        copied = self.base / 'copied-repo'
        shutil.copytree(self.root, copied)
        proof = ci.prepare_derived_data(copied, self.native)
        self.assertTrue(proof['reset'])
        self.assertEqual(proof['previousOwner']['checkout'], str(self.root.resolve()))
        self.assertFalse((copied / 'ios/build/dd/ModuleCache.noindex').exists())
        self.assertFalse((copied / 'ios/build/dd/Build').exists())
        self.assertTrue((copied / 'ios/build/dd/SourcePackages/checkouts/package/source.swift').exists())
        self.assertTrue((directory / 'ModuleCache.noindex/old.pch').exists())

    def test_native_execution_clears_unowned_cache_before_unit_build(self):
        directory = self.root / 'ios/build/dd'
        directory.mkdir(parents=True)
        stale = directory / 'ModuleCache.noindex'
        stale.mkdir()
        (stale / 'old.pch').write_text('copied cache without ownership')
        original_phase = self.phase

        def phase(name, *args):
            if name == 'unit':
                self.assertFalse(stale.exists())
            return original_phase(name, *args)

        self.phase = phase
        self.assertEqual(self.run_ci(), 0)
        proof = json.loads((Path(self.latest()['attempt']) / 'derived-data.json').read_text())
        self.assertTrue(proof['reset'])
        self.assertIn('ModuleCache.noindex', proof['removed'])

    def test_derived_data_reuses_same_path_and_resets_changed_toolchain(self):
        ci.prepare_derived_data(self.root, self.native)
        compiled = self.root / 'ios/build/dd/Build/keep.o'
        compiled.parent.mkdir()
        compiled.write_text('compiled')
        self.assertFalse(ci.prepare_derived_data(self.root, self.native)['reset'])
        self.assertTrue(compiled.exists())
        changed = dict(self.native, xcode='Xcode 27.0')
        self.assertTrue(ci.prepare_derived_data(self.root, changed)['reset'])
        self.assertFalse(compiled.exists())

    def test_derived_data_rejects_link_without_touching_external_cache(self):
        external = self.base / 'external-cache'
        external.mkdir()
        sentinel = external / 'keep.pch'
        sentinel.write_text('external')
        directory = self.root / 'ios/build/dd'
        directory.parent.mkdir(parents=True)
        directory.symlink_to(external, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            ci.prepare_derived_data(self.root, self.native)
        self.assertTrue(sentinel.exists())

    def test_simulator_source_drift_prevents_success(self):
        self.args.mode = 'simulator'
        changed = dict(self.identity, fingerprint='c' * 64)
        self.assertEqual(self.run_ci([self.identity, changed]), 1)
        self.assertEqual(self.latest()['status'], 'failed')
        self.assertFalse((self.state / 'success-simulator.json').exists())

    def test_dependency_audit_failure_stops_build_and_cached_reuse(self):
        for mode in ('simulator', 'check'):
            with self.subTest(mode=mode):
                self.args.mode = mode
                self.failure_phase = 'dependency-audit'
                self.calls.clear()
                self.assertEqual(self.run_ci(), 1)
                self.assertNotIn('build', self.calls)
                self.assertNotIn('rust-setup', self.calls)
                self.failure_phase = None
                self.assertEqual(self.run_ci(), 0)
                self.calls.clear()
                self.failure_phase = 'dependency-audit'
                self.assertEqual(self.run_ci(), 1)
                self.assertNotIn('build', self.calls)
                self.assertNotIn('rust-setup', self.calls)
                self.assertEqual(self.latest()['status'], 'failed')
                self.assertFalse((self.state / ('success-simulator.json' if mode == 'simulator'
                                              else 'success.json')).exists())
                self.assertEqual(self.commands['dependency-audit'][0],
                                 ['npm', 'audit', '--package-lock-only', '--audit-level=moderate'])

    def test_cached_native_proof_without_dependency_audit_is_not_reusable(self):
        self.assertEqual(self.run_ci(), 0)
        cached = self.state / 'success.json'
        proof = json.loads(cached.read_text())
        proof['phases'] = [p for p in proof['phases'] if p['name'] != 'dependency-audit']
        cached.write_text(json.dumps(proof))
        self.assertIsNone(ci.reuse(self.state, self.identity, self.native, False))

    def test_simulator_preflight_and_failure_do_not_admit_test_proof(self):
        self.args.mode = 'simulator'
        self.args.preflight = True
        self.assertEqual(self.run_ci(), 0)
        self.assertEqual(self.latest()['status'], 'preflight')
        self.assertNotIn('build', self.calls)
        self.assertFalse((self.state / 'success-simulator.json').exists())
        self.args.preflight = False
        self.assertEqual(self.run_ci(), 0)
        proof = self.latest()
        (Path(proof['attempt']) / 'ui-smoke-attachments/candidate.png').write_bytes(b'tampered')
        self.assertIsNone(ci.reuse(self.state, self.identity, self.native, False, 'simulator'))
        self.failure_phase = 'unit'
        self.assertEqual(self.run_ci(), 1)
        self.assertFalse((self.state / 'success-simulator.json').exists())

    def test_cli_defaults_to_simulator_and_keeps_explicit_check(self):
        for flags, expected in (([], 'simulator'), (['--mode', 'check'], 'check')):
            with self.subTest(mode=expected), \
                    patch.object(sys, 'argv', ['ios-ci.py'] + flags), \
                    patch.dict(os.environ, {'PAPERCUP_IOS_CI_STATE': str(self.state)}), \
                    patch.object(ci, 'execute', return_value=0) as execute:
                self.assertEqual(ci.main(), 0)
                self.assertEqual(execute.call_args.args[2].mode, expected)

    def test_simulator_toolchain_accepts_existing_xcode_and_pinned_modern_iphone(self):
        runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-18-6'
        sims = {'devices': {
            'com.apple.CoreSimulator.SimRuntime.iOS-26-0': [
                {'udid': 'UNAVAILABLE', 'name': 'iPhone 17', 'isAvailable': False}],
            runtime: [{'udid': 'PHONE', 'name': 'iPhone 16', 'isAvailable': True}],
            'com.apple.CoreSimulator.SimRuntime.iOS-16-4': [
                {'udid': 'OLD', 'name': 'iPhone 14', 'isAvailable': True}]}}
        env = {'PATH': '/fixture', 'DEVELOPER_DIR': '/Xcode16', 'PAPERCUP_IOS_SIM_UDID': 'PHONE'}
        with patch.object(ci.platform, 'system', return_value='Darwin'), \
                patch.object(ci.shutil, 'which', side_effect=lambda name, **unused: None if name == 'security' else '/fixture/tool'), \
                patch.object(ci, 'output', side_effect=['18.5', 'Xcode 16.4\nBuild version fixture', json.dumps(sims)]) as output:
            tools = ci.toolchain(self.root, env, 'simulator')
        self.assertEqual(tools['simulator'], 'PHONE')
        self.assertEqual(tools['simulatorRuntime'], runtime)
        self.assertEqual(tools['simulatorSDK'], '18.5')
        self.assertNotIn('iosSDK', tools)
        self.assertEqual(output.call_args_list[0].args[0][2], 'iphonesimulator')

    def test_simulator_toolchain_refuses_old_sdk_xcode_and_unavailable_selection(self):
        cases = [
            (['16.4'], {}, 'SDK17'),
            (['18.5', 'Xcode 16.2'], {}, 'Xcode16.3'),
            (['18.5', 'Xcode 16.4', '{"devices":{}}'], {}, 'iOS17'),
            (['18.5', 'Xcode 16.4', json.dumps({'devices': {
                'com.apple.CoreSimulator.SimRuntime.iOS-18-6': [
                    {'udid': 'AVAILABLE', 'name': 'iPhone 16', 'isAvailable': True}]}})],
             {'PAPERCUP_IOS_SIM_UDID': 'MISSING'}, 'iOS17')]
        for responses, extra, message in cases:
            with self.subTest(message=message), \
                    patch.object(ci.platform, 'system', return_value='Darwin'), \
                    patch.object(ci.shutil, 'which', return_value='/fixture/tool'), \
                    patch.object(ci, 'output', side_effect=responses):
                with self.assertRaisesRegex(ValueError, message):
                    ci.toolchain(self.root, dict({'PATH': '/fixture'}, **extra), 'simulator')

    def test_unpinned_simulator_chooses_newest_available_iphone_runtime(self):
        sims = {'devices': {
            'com.apple.CoreSimulator.SimRuntime.iOS-18-6': [
                {'udid': 'OLDER', 'name': 'iPhone 16', 'isAvailable': True}],
            'com.apple.CoreSimulator.SimRuntime.iOS-26-0': [
                {'udid': 'TABLET', 'name': 'iPad Pro', 'isAvailable': True},
                {'udid': 'OFFLINE', 'name': 'iPhone 17 Pro', 'isAvailable': False},
                {'udid': 'NEWER', 'name': 'iPhone 17', 'isAvailable': True}]}}
        with patch.object(ci.platform, 'system', return_value='Darwin'), \
                patch.object(ci.shutil, 'which', return_value='/fixture/tool'), \
                patch.object(ci, 'output', side_effect=['26.0', 'Xcode 26.0', json.dumps(sims)]):
            tools = ci.toolchain(self.root, {'PATH': '/fixture', 'DEVELOPER_DIR': '/Xcode'}, 'simulator')
        self.assertEqual(tools['simulator'], 'NEWER')

    def test_simulator_runs_private_paired_ui_with_no_archive(self):
        self.args.mode = 'simulator'
        self.args.paired_ui = True
        payload = self.base / 'pair.json'
        payload.write_text('{"token":"fixture"}')
        payload.chmod(0o600)
        self.args.pair_payload_file = str(payload)
        real_summary = self.summary

        def summary(command, **kwargs):
            self.counts['passedTests'] = 1 if 'paired-ui.xcresult' in ' '.join(command) else len(ci.SMOKE_TESTS)
            return real_summary(command, **kwargs)

        with patch.object(self, 'summary', side_effect=summary):
            self.assertEqual(self.run_ci(), 0)
        self.assertIn('paired-ui-guard', self.calls)
        self.assertIn('paired-ui-screenshots', self.calls)
        self.assertNotIn('archive', self.calls)
        self.assertIsNone(ci.reuse(self.state, self.identity, self.native, False, 'simulator'))

    def reinstall_fixture(self):
        app = self.root / 'ios/build/dd/Build/Products/Debug-iphonesimulator/Papercup.app'
        app.mkdir(parents=True)
        (app / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.papercuspai.operator.mobile'}))
        original = self.base / 'original-data'
        original.mkdir()
        installed = self.base / 'new-data'
        attempt = self.state / 'reinstall'
        attempt.mkdir()
        env = {'PAPERCUP_IOS_SIM_UDID': 'SIM', 'TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD': 'private-one-shot'}
        return app, original, installed, attempt, env

    def test_reinstall_requires_positive_relaunch_then_removes_os_container_without_reusing_token(self):
        app, original, installed, attempt, env = self.reinstall_fixture()
        observed = []

        def ui(root, environment, dest, phases, name, tests, shared_simulator):
            observed.append((name, dict(environment), shared_simulator))

        def phase(name, command, *unused):
            observed.append((name, command))
            if name == 'reinstall-uninstall':
                original.rmdir()
            if name == 'reinstall-install':
                installed.mkdir()

        with patch.object(ci, 'ui_test', side_effect=ui), \
                patch.object(ci, 'output', side_effect=[str(original), str(installed)]), \
                patch.object(ci, 'run_phase', side_effect=phase), \
                patch.object(ci.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
            ci.reinstall_ui(self.root, env, attempt, [])
        self.assertEqual([row[0] for row in observed], [
            'reinstall-pair', 'reinstall-relaunch', 'reinstall-uninstall',
            'reinstall-install', 'reinstall-onboarding'])
        self.assertEqual(observed[0][1]['TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD'], 'private-one-shot')
        for row in (observed[1], observed[4]):
            self.assertNotIn('TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD', row[1])
            self.assertTrue(row[2], 'UI must use the exact simctl device, never a clone')
        self.assertEqual(observed[2][1], [
            'xcrun', 'simctl', 'uninstall', 'SIM', 'com.papercuspai.operator.mobile'])
        self.assertEqual(observed[3][1], ['xcrun', 'simctl', 'install', 'SIM', str(app)])
        proof = json.loads((attempt / 'reinstall.json').read_text())
        self.assertTrue(proof['uninstallVerified'])
        self.assertTrue(proof['newDataContainerVerified'])
        self.assertNotIn('private-one-shot', (attempt / 'reinstall.json').read_text())

    def test_reinstall_stops_before_install_if_os_container_survives_or_app_is_still_installed(self):
        for returncode, remove in ((1, False), (0, True)):
            with self.subTest(returncode=returncode, remove=remove):
                app, original, installed, attempt, env = self.reinstall_fixture()

                def phase(name, command, *unused):
                    if remove:
                        original.rmdir()

                with patch.object(ci, 'ui_test'), \
                        patch.object(ci, 'output', return_value=str(original)), \
                        patch.object(ci, 'run_phase', side_effect=phase) as native, \
                        patch.object(ci.subprocess, 'run', return_value=subprocess.CompletedProcess([], returncode)):
                    with self.assertRaisesRegex(ValueError, 'Uninstall did not remove'):
                        ci.reinstall_ui(self.root, env, attempt, [])
                self.assertEqual([call.args[0] for call in native.call_args_list], ['reinstall-uninstall'])
                self.assertFalse((attempt / 'reinstall.json').exists())
                shutil.rmtree(app)
                shutil.rmtree(attempt)
                if original.exists():
                    original.rmdir()

    def test_reinstall_refuses_reused_container_and_never_publishes_success(self):
        app, original, installed, attempt, env = self.reinstall_fixture()

        def phase(name, command, *unused):
            if name == 'reinstall-uninstall':
                original.rmdir()
            else:
                original.mkdir()

        with patch.object(ci, 'ui_test') as ui, \
                patch.object(ci, 'output', return_value=str(original)), \
                patch.object(ci, 'run_phase', side_effect=phase), \
                patch.object(ci.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
            with self.assertRaisesRegex(ValueError, 'different app data container'):
                ci.reinstall_ui(self.root, env, attempt, [])
        self.assertEqual(ui.call_count, 2)
        self.assertFalse((attempt / 'reinstall.json').exists())

    def test_reinstall_cannot_uninstall_before_positive_pairing_and_relaunch_pass(self):
        app, original, installed, attempt, env = self.reinstall_fixture()
        with patch.object(ci, 'ui_test', side_effect=[None, RuntimeError('positive control failed')]), \
                patch.object(ci, 'run_phase') as native:
            with self.assertRaisesRegex(RuntimeError, 'positive control failed'):
                ci.reinstall_ui(self.root, env, attempt, [])
        native.assert_not_called()
        self.assertTrue(original.exists())

    def test_reinstall_refuses_wrong_app_and_incompatible_or_missing_private_input_before_build(self):
        app, original, installed, attempt, env = self.reinstall_fixture()
        (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'another.app'}))
        with patch.object(ci, 'ui_test') as ui:
            with self.assertRaisesRegex(ValueError, 'built Papercup simulator app'):
                ci.reinstall_ui(self.root, env, attempt, [])
        ui.assert_not_called()
        self.args.reinstall_ui = True
        for mode, paired in (('signed', False), ('simulator', True), ('simulator', False)):
            self.args.mode, self.args.paired_ui = mode, paired
            with self.subTest(mode=mode, paired=paired):
                self.assertEqual(self.run_ci(), 1)
                self.assertNotIn('build', self.calls)

    def test_failed_ui_retains_native_summary_and_attachments_without_admitting_success(self):
        self.args.mode = 'simulator'
        self.failure_phase = 'ui-smoke'
        self.counts = {'passedTests': 4, 'failedTests': 1, 'skippedTests': 0}
        self.assertEqual(self.run_ci(), 1)
        result = self.latest()
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['error'], 'fixture failure: ui-smoke')
        self.assertIn('ui-smoke-screenshots', self.calls)
        retained = {entry['path'] for entry in result['artifacts']}
        self.assertIn('ui-smoke-summary.json', retained)
        self.assertIn('ui-smoke-attachments/candidate.png', retained)
        self.assertIn('ui-smoke-diagnostic-errors.json', retained)
        self.assertFalse((self.state / 'success-simulator.json').exists())

    def test_failed_summary_export_still_retains_attachments_and_original_ui_failure(self):
        self.args.mode = 'simulator'
        self.failure_phase = 'ui-smoke'
        def unavailable_summary(command, **kwargs):
            raise subprocess.CalledProcessError(1, command)
        self.summary = unavailable_summary
        self.assertEqual(self.run_ci(), 1)
        result = self.latest()
        self.assertEqual(result['error'], 'fixture failure: ui-smoke')
        self.assertIn('ui-smoke-screenshots', self.calls)
        errors = json.loads((Path(result['attempt']) / 'ui-smoke-diagnostic-errors.json').read_text())
        self.assertEqual(errors, [{'stage': 'summary', 'errorType': 'CalledProcessError'}])

    def test_shared_simulator_selection_disables_cloning_and_keeps_result_guard(self):
        self.counts = {'passedTests': 1, 'failedTests': 0, 'skippedTests': 0}
        real_run = subprocess.run

        def native_run(command, **kwargs):
            if command[0] == 'xcrun':
                return self.summary(command, **kwargs)
            return real_run(command, **kwargs)

        with patch.object(ci, 'run_phase', side_effect=self.phase), \
                patch.object(ci.subprocess, 'run', side_effect=native_run):
            ci.ui_test(self.root, {'PAPERCUP_IOS_SIM_UDID': 'SIM'}, self.state, [],
                       'reinstall-onboarding', ('PapercupUITests/PairFlowUITests/testActualReinstallClearsOldPairing',), True)
        command = self.commands['reinstall-onboarding'][0]
        self.assertEqual(command[command.index('-parallel-testing-enabled') + 1], 'NO')
        self.assertIn('reinstall-onboarding-guard', self.calls)
        self.assertIn('reinstall-onboarding-screenshots', self.calls)

    def test_reinstall_option_executes_with_private_payload_instead_of_reusing_cached_success(self):
        self.args.mode = 'simulator'
        self.assertEqual(self.run_ci(), 0)
        self.calls.clear()
        self.args.reinstall_ui = True
        payload = self.base / 'pair.json'
        payload.write_text('{"token":"private-reinstall"}')
        payload.chmod(0o600)
        self.args.pair_payload_file = str(payload)
        with patch.object(ci, 'reinstall_ui') as reinstall:
            self.assertEqual(self.run_ci(), 0)
        self.assertIn('build', self.calls)
        reinstall.assert_called_once()
        self.assertEqual(reinstall.call_args.args[1]['TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD'], payload.read_text())
        self.assertTrue(self.latest()['reinstallUI'])
        self.assertTrue(self.latest()['pairedUI'])
        self.assertEqual(self.latest()['status'], 'passed')
        self.assertIsNone(ci.reuse(self.state, self.identity, self.native, False, 'simulator'))

    def test_release_modes_still_require_current_device_sdk_and_xcode(self):
        for mode in ('check', 'signed'):
            for responses, message in ((['18.5'], 'SDK26'), (['26.0', 'Xcode 16.4'], 'Xcode26')):
                with self.subTest(mode=mode, message=message), \
                        patch.object(ci.platform, 'system', return_value='Darwin'), \
                        patch.object(ci.shutil, 'which', return_value='/fixture/tool'), \
                        patch.object(ci, 'output', side_effect=responses):
                    with self.assertRaisesRegex(ValueError, message):
                        ci.toolchain(self.root, {'PATH': '/fixture'}, mode)

    def test_pass_retains_source_results_screenshot_and_archive(self):
        self.assertEqual(self.run_ci(), 0)
        result = self.latest()
        self.assertEqual(result['status'], 'passed')
        self.assertEqual(result['source'], self.identity)
        names = {a['path'] for a in result['artifacts']}
        self.assertIn('ui-smoke-summary.json', names)
        self.assertIn('ui-smoke-attachments/candidate.png', names)
        self.assertIn('candidate-manifest.json', names)
        self.assertTrue((self.state / 'success.json').exists())

    def test_preflight_is_never_test_success(self):
        self.args.preflight = True
        self.assertEqual(self.run_ci(), 0)
        self.assertEqual(self.latest()['status'], 'preflight')
        self.assertNotIn('build', self.calls)
        self.assertFalse((self.state / 'success.json').exists())

    def test_failure_keeps_logs_and_revokes_old_success(self):
        (self.state / 'success.json').write_text('{}')
        self.failure_phase = 'build'
        self.assertEqual(self.run_ci(), 1)
        self.assertEqual(self.latest()['status'], 'failed')
        self.assertIn('build.log', {a['path'] for a in self.latest()['artifacts']})
        self.assertNotIn('archive', self.calls)
        self.assertFalse((self.state / 'success.json').exists())

    def test_source_drift_prevents_admission_and_upload(self):
        self.args.mode = 'signed'
        self.args.build_number = '42'
        self.args.upload = self.args.confirm_upload = True
        changed = dict(self.identity, fingerprint='c' * 64)
        self.assertEqual(self.run_ci([self.identity, changed]), 1)
        self.assertNotIn('testflight-upload', self.calls)
        self.assertIn('signing-cleanup', self.calls)

    def test_upload_requires_explicit_confirmation_before_any_phase(self):
        self.args.upload = True
        self.assertEqual(self.run_ci(), 1)
        self.assertEqual(self.calls, [])

    def test_signed_failure_cleans_material_and_preserves_evidence(self):
        self.args.mode = 'signed'
        self.args.build_number = '42'
        self.failure_phase = 'signed-export'
        self.assertEqual(self.run_ci(), 1)
        self.assertIn('signing-cleanup', self.calls)
        self.assertIn('signed-export.log', {a['path'] for a in self.latest()['artifacts']})

    def test_reserved_build_number_cannot_be_reused(self):
        (self.state / 'last-build-number.json').write_text('{"buildNumber":42}')
        self.args.mode = 'signed'
        self.args.build_number = '42'
        self.assertEqual(self.run_ci(), 1)
        self.assertNotIn('signing-install', self.calls)

    def test_cleanup_failure_is_failed_and_still_has_evidence(self):
        self.args.mode = 'signed'
        self.args.build_number = '42'
        self.failure_phase = 'signing-cleanup'
        self.assertEqual(self.run_ci(), 1)
        self.assertEqual(self.latest()['status'], 'failed')
        self.assertIn('signing-cleanup.log', {a['path'] for a in self.latest()['artifacts']})

    def test_skipped_and_empty_ui_suites_cannot_pass(self):
        for counts in ({'passedTests': 2, 'failedTests': 0, 'skippedTests': 1},
                       {'passedTests': 0, 'failedTests': 0, 'skippedTests': 0},
                       {'passedTests': 3, 'failedTests': 1, 'skippedTests': 0}):
            with self.subTest(counts=counts):
                self.counts = counts
                self.assertEqual(self.run_ci(), 1)
                self.assertEqual(self.latest()['status'], 'failed')
                self.assertNotIn('archive', self.calls)

    def test_tampered_artifact_prevents_reuse(self):
        self.assertEqual(self.run_ci(), 0)
        proof = self.latest()
        self.assertIsNotNone(ci.reuse(self.state, self.identity, self.native, False))
        (Path(proof['attempt']) / 'ui-smoke-attachments/candidate.png').write_bytes(b'changed')
        self.assertIsNone(ci.reuse(self.state, self.identity, self.native, False))

    def test_signed_export_extends_existing_candidate_manifest(self):
        self.args.mode = 'signed'
        self.args.build_number = '42'
        self.assertEqual(self.run_ci(), 0)
        result = self.latest()
        manifest = json.loads((Path(result['attempt']) / 'candidate-manifest.json').read_text())
        self.assertEqual(manifest['schemaVersion'], 1)
        self.assertEqual(manifest['sourceCommit'], self.identity['commit'])
        self.assertIs(manifest['sourceDirty'], False)
        self.assertIs(manifest['signed'], True)
        self.assertEqual(manifest['releaseVersion'], '1.0.0')
        self.assertEqual(manifest['builtAt'], result['finishedAt'])
        self.assertEqual(manifest['artifacts'], [{
            'kind': 'ipa', 'path': 'export/app.ipa',
            'size': (Path(result['attempt']) / 'export/app.ipa').stat().st_size,
            'sha256': ci.digest(Path(result['attempt']) / 'export/app.ipa')}])

    def test_registered_device_export_records_install_prerequisites_without_upload(self):
        self.args.mode = 'signed'
        self.args.distribution = 'release-testing'
        self.args.build_number = '42'
        self.assertEqual(self.run_ci(), 0)
        result = self.latest()
        self.assertNotIn('testflight-upload', self.calls)
        manifest = json.loads((Path(result['attempt']) / 'candidate-manifest.json').read_text())
        self.assertEqual(manifest['installation'], {
            'distributionMethod': 'release-testing', 'registeredDeviceCount': 2,
            'profileExpiresAt': '2030-01-01T00:00:00+00:00', 'installationRoute': 'registered-device'})

    def test_registered_device_upload_refuses_before_build_or_signing(self):
        self.args.mode = 'signed'
        self.args.distribution = 'release-testing'
        self.args.upload = self.args.confirm_upload = True
        self.assertEqual(self.run_ci(), 1)
        self.assertEqual(self.calls, [])

    def test_exported_ipa_must_have_one_matching_profile(self):
        ipa = self.base / 'app.ipa'
        env = {'APPLE_TEAM_ID': 'ABCDE12345', 'PAPERCUP_SIGNING_CERT_SHA1': 'C' * 40,
               'PAPERCUP_EXPORT_METHOD': 'release-testing'}
        with zipfile.ZipFile(ipa, 'w') as archive:
            archive.writestr('Payload/Papercup.app/Info.plist', b'fixture')
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            ci.exported_profile(self.root, env, ipa)
        with zipfile.ZipFile(ipa, 'a') as archive:
            archive.writestr('Payload/Papercup.app/embedded.mobileprovision', b'fixture')
        with patch.object(ci, 'output', return_value=json.dumps({'certificateSha1s': ['D' * 40]})):
            with self.assertRaisesRegex(ValueError, 'installed distribution identity'):
                ci.exported_profile(self.root, env, ipa)

    def test_private_export_config_needs_four_inputs_but_upload_needs_seven(self):
        config = self.base / 'signing.json'
        config.write_text(json.dumps({key: 'fixture' for key in ci.SIGNING_KEYS[:4]}))
        config.chmod(0o600)
        env = {'PAPERCUP_REQUIRE_UPLOAD_SECRETS': '0'}
        with patch.object(ci.subprocess, 'run') as gate:
            ci.load_signing(config, self.root, env)
            gate.assert_called_once()
        env['PAPERCUP_REQUIRE_UPLOAD_SECRETS'] = '1'
        with self.assertRaisesRegex(ValueError, 'required signing inputs'):
            ci.load_signing(config, self.root, env)

    def test_private_paired_ui_is_checked_before_expensive_build_and_runs_selected_test(self):
        self.args.paired_ui = True
        self.assertEqual(self.run_ci(), 1)
        self.assertEqual(self.calls, [])
        payload = self.base / 'pair.json'
        payload.write_text('{"token":"fixture"}')
        payload.chmod(0o600)
        self.args.pair_payload_file = str(payload)
        self.counts = {'passedTests': 1, 'failedTests': 0, 'skippedTests': 0}
        real_summary = self.summary
        def summary(command, **kwargs):
            self.counts['passedTests'] = 1 if 'paired-ui.xcresult' in ' '.join(command) else len(ci.SMOKE_TESTS)
            return real_summary(command, **kwargs)
        with patch.object(self, 'summary', side_effect=summary):
            self.assertEqual(self.run_ci(), 0)
        self.assertIn('paired-ui-guard', self.calls)
        self.assertIs(self.latest()['pairedUI'], True)

    def test_check_and_failed_cleanup_do_not_emit_release_envelope(self):
        self.assertEqual(self.run_ci(), 0)
        manifest = Path(self.latest()['attempt']) / 'candidate-manifest.json'
        self.assertNotIn('schemaVersion', json.loads(manifest.read_text()))
        self.args.mode = 'signed'
        self.args.build_number = '42'
        self.failure_phase = 'signing-cleanup'
        self.assertEqual(self.run_ci(), 1)
        manifest = Path(self.latest()['attempt']) / 'candidate-manifest.json'
        self.assertNotIn('schemaVersion', json.loads(manifest.read_text()))

    def test_failure_before_unit_does_not_collect_previous_run_results(self):
        build = self.root / 'ios/build'
        build.mkdir(parents=True)
        (build / 'unit-stale.json').write_text('{"passedTests":99}')
        self.failure_phase = 'build'
        self.assertEqual(self.run_ci(), 1)
        self.assertNotIn('unit-stale.json', {a['path'] for a in self.latest()['artifacts']})

    def test_generic_pairing_uses_private_paste_and_clears_the_clipboard(self):
        source = (ROOT / 'ios/PapercupUITests/PairFlowUITests.swift').read_text()
        generic = source.split('func testPairAndPairedNavigation() throws {', 1)[1].split(
            'func testLiveRevocationAndRepairing()', 1)[0]
        self.assertIn('try pastePairPayload(app, payload: payload)', generic)
        self.assertNotIn('typeText(payload)', generic)
        self.assertIn('defer { UIPasteboard.general.string = nil; app.terminate() }', generic)

    def test_private_ui_discards_raw_results_and_failed_screenshots_before_artifact_retention(self):
        payload = json.dumps({'pairToken': 'NONSECRET-CANARY-pair-token',
                              'server': 'https://canary.invalid'})
        env = {'TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD': payload, 'PAPERCUP_IOS_SIM_UDID': 'SIM'}
        for failed in (False, True):
            with self.subTest(failed=failed):
                attempt = self.base / ('private-ui-' + str(failed))
                attempt.mkdir()
                phases = []
                bundle = attempt / 'paired-ui.xcresult'

                def native(name, command, root, env, attempt, phases):
                    if name.endswith('-guard'):
                        return
                    self.phase(name, command, root, env, attempt, phases)
                    if name == 'paired-ui':
                        bundle.mkdir()
                        (bundle / 'opaque-record').write_bytes(payload.encode('utf-16'))
                        if failed:
                            raise RuntimeError('canary native failure')

                def summary(command, **kwargs):
                    kwargs['stdout'].write(json.dumps({'passedTests': 1, 'failedTests': 0,
                        'skippedTests': 0, 'diagnostic': 'NONSECRET-CANARY-pair-token'}))
                    return subprocess.CompletedProcess(command, 0)

                with patch.object(ci, 'run_phase', side_effect=native), \
                        patch.object(ci.subprocess, 'run', side_effect=summary):
                    if failed:
                        with self.assertRaisesRegex(RuntimeError, 'canary native failure'):
                            ci.ui_test(self.root, env, attempt, phases, 'paired-ui', ('selected-test',))
                    else:
                        ci.ui_test(self.root, env, attempt, phases, 'paired-ui', ('selected-test',))
                self.assertFalse(bundle.exists(), 'Opaque native results must not retain private input')
                self.assertEqual((attempt / 'paired-ui-attachments/candidate.png').exists(), not failed)
                self.assertNotIn('NONSECRET-CANARY-pair-token',
                                 (attempt / 'paired-ui-summary.json').read_text())
                for artifact in ci.artifacts(attempt):
                    data = (attempt / artifact['path']).read_bytes()
                    self.assertNotIn(b'NONSECRET-CANARY-pair-token', data)
                    self.assertNotIn(payload.encode('utf-16'), data)

    def test_paired_and_signing_failure_logs_are_redacted_before_hashing(self):
        attempt = self.base / 'logs'
        attempt.mkdir()
        phases = []
        payload = '{"token":"private-token","server":"https://private.example"}'
        expired_payload = '{"pairToken":"expired-private-token","server":"https://private.example"}'
        env = {'TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD': payload,
               'TEST_RUNNER_PAPERCUP_EXPIRED_PAIR_PAYLOAD': expired_payload,
               'IOS_DIST_CERT_PASSWORD': 'private-password'}

        def noisy_failure(name, command, root, env, attempt, phases):
            log = attempt / (name + '.log')
            log.write_text(payload + '\n' + expired_payload +
                           '\nprivate-token\nexpired-private-token\nprivate-password\n')
            phases.append({'name': name, 'sha256': ci.digest(log)})
            raise RuntimeError('fixture failed')

        with patch.object(ci.mobile_ci, 'run_phase', side_effect=noisy_failure):
            with self.assertRaisesRegex(RuntimeError, 'fixture failed'):
                ci.run_phase('paired-ui', [], self.root, env, attempt, phases)
        text = (attempt / 'paired-ui.log').read_text()
        self.assertNotIn(payload, text)
        self.assertNotIn(expired_payload, text)
        self.assertNotIn('expired-private-token', text)
        self.assertNotIn('private-token', text)
        self.assertNotIn('private-password', text)
        self.assertEqual(phases[0]['sha256'], ci.digest(attempt / 'paired-ui.log'))

    def test_retention_preserves_admitted_and_signed_candidates(self):
        attempts = self.state / 'attempts'
        attempts.mkdir()
        paths = []
        for number in range(5):
            attempt = attempts / ('20260101T00000' + str(number) + 'Z-00000000')
            attempt.mkdir()
            (attempt / 'result.json').write_text(json.dumps({
                'executor': 'native-mac', 'attempt': str(attempt),
                'mode': 'signed' if number == 1 else 'simulator' if number == 2 else 'check'}))
            paths.append(attempt)
        (self.state / 'success.json').write_text(json.dumps({'attempt': str(paths[0])}))
        (self.state / 'success-simulator.json').write_text(json.dumps({'attempt': str(paths[2])}))
        (self.state / 'latest.json').write_text(json.dumps({'attempt': str(paths[4])}))
        unknown = attempts / 'not-runner-owned'
        unknown.mkdir()
        ci.prune_attempts(self.state, keep=1)
        self.assertTrue(paths[0].exists())
        self.assertTrue(paths[1].exists())
        self.assertTrue(paths[2].exists())
        self.assertFalse(paths[3].exists())
        self.assertTrue(paths[4].exists())
        self.assertTrue(unknown.exists())

    def test_launch_agent_installs_simulator_checks_with_selected_xcode(self):
        (self.root / 'tools/ci').mkdir(parents=True)
        template = ROOT / 'tools/ci/com.papercusp.ios-ci.plist'
        (self.root / 'tools/ci/com.papercusp.ios-ci.plist').write_bytes(template.read_bytes())
        with patch.object(ci.platform, 'system', return_value='Darwin'), \
                patch.object(ci, 'toolchain', return_value=self.native), \
                patch.object(ci.Path, 'home', return_value=self.base), \
                patch.dict(os.environ, {'DEVELOPER_DIR': '/Xcode26/Contents/Developer'}), \
                patch.object(ci.subprocess, 'run') as launch:
            ci.install_launch_agent(self.root, self.state)
        target = self.base / 'Library/LaunchAgents/com.papercusp.ios-ci.plist'
        installed = plistlib.loads(target.read_bytes())
        self.assertEqual(installed['ProgramArguments'][-2:], ['--mode', 'simulator'])
        self.assertEqual(installed['StartInterval'], 1800)
        self.assertTrue(installed['RunAtLoad'])
        self.assertEqual(installed['EnvironmentVariables']['DEVELOPER_DIR'], '/Xcode26/Contents/Developer')
        self.assertEqual(launch.call_args_list[-1].args[0][1], 'bootstrap')

    def test_launch_agent_refuses_unsupported_toolchain_before_installing(self):
        with patch.object(ci.platform, 'system', return_value='Darwin'), \
                patch.object(ci, 'toolchain', side_effect=ValueError('SDK17+ required')), \
                patch.object(ci.Path, 'home', return_value=self.base), \
                patch.object(ci.subprocess, 'run') as launch:
            with self.assertRaisesRegex(ValueError, 'SDK17'):
                ci.install_launch_agent(self.root, self.state)
        self.assertFalse((self.base / 'Library/LaunchAgents/com.papercusp.ios-ci.plist').exists())
        launch.assert_not_called()

    def test_private_inputs_reject_repository_or_public_files(self):
        inside = self.root / 'secret.json'
        inside.write_text('{}')
        inside.chmod(0o600)
        with self.assertRaisesRegex(ValueError, 'outside'):
            ci.private_input(inside, self.root)
        public = self.base / 'public.json'
        public.write_text('{}')
        public.chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'owner-only'):
            ci.private_input(public, self.root)

    def test_old_sdk_and_unavailable_intel_simulator_refuse(self):
        with patch.object(ci.platform, 'system', return_value='Darwin'), \
                patch.object(ci.shutil, 'which', return_value='/fixture/tool'), \
                patch.object(ci, 'output', return_value='18.5'):
            with self.assertRaisesRegex(ValueError, 'SDK26'):
                ci.toolchain(self.root, {'PATH': '/fixture'})
        with patch.object(ci.platform, 'system', return_value='Darwin'), \
                patch.object(ci.shutil, 'which', return_value='/fixture/tool'), \
                patch.object(ci, 'output', side_effect=['26.5', 'Xcode 26.6\nBuild version fixture', '{"devices":{}}']):
            with self.assertRaisesRegex(ValueError, 'universal runtime'):
                ci.toolchain(self.root, {'PATH': '/fixture'})


class NativePackagingTests(unittest.TestCase):
    """Exercise real packaging without a Mac; source headers are Xcode inputs."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        scripts = self.root / 'tools/build-scripts'
        scripts.mkdir(parents=True)
        self.builder = scripts / 'build-ios.sh'
        self.builder.write_text((ROOT / 'tools/build-scripts/build-ios.sh').read_text())
        for helper in ('check-ios-build-host-health.sh', 'ensure-swiftformat.sh'):
            path = scripts / helper
            path.write_text('#!/bin/bash\nexit 0\n')
            path.chmod(0o755)
        (self.root / 'Cargo.lock').touch()
        config = self.root / 'crates/papercup-bindings/uniffi.toml'
        config.parent.mkdir(parents=True)
        config.write_text((ROOT / 'crates/papercup-bindings/uniffi.toml').read_text())
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        commands = {
            'uname': '#!/bin/bash\necho Darwin\n',
            'rustup': '#!/bin/bash\nexit 0\n',
            'cargo': r"""#!/bin/bash
set -eu
if [ "$1" = run ]; then
    # UniFFI 0.32 treats --config as global config; the crate-local flat
    # config must be discovered as in the maintained binding targets.
    for argument in "$@"; do
        if [ "$argument" = --config ]; then
            echo 'retired flat config override' >&2
            exit 2
        fi
    done
    mkdir -p ios/PapercupCore
    printf '// current generated Swift\n' > ios/PapercupCore/papercup.swift
    if [ "$TEST_OMIT_HEADER" = 0 ]; then
        printf '// current generated header\n' > ios/PapercupCore/papercupFFI.h
    fi
    printf 'module papercupFFI {}\n' > ios/PapercupCore/papercupFFI.modulemap
fi
""",
            'lipo': '#!/bin/bash\nexit 0\n',
            'xcodebuild': r"""#!/bin/bash
set -eu
# Existing XcodeGen projects refer to the original generated source paths.
test -f ios/PapercupCore/papercup.swift
cmp ios/PapercupCore/papercupFFI.h ios/PapercupCore/headers/papercupFFI.h
cmp ios/PapercupCore/papercupFFI.modulemap ios/PapercupCore/headers/module.modulemap
mkdir -p ios/PapercupCore.xcframework
touch ios/PapercupCore.xcframework/packaged
""",
        }
        for name, script in commands.items():
            path = self.bin / name
            path.write_text(script)
            path.chmod(0o755)

    def build(self, omit_header=False):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                   TEST_OMIT_HEADER=str(int(omit_header)))
        return subprocess.run(['bash', str(self.builder)], cwd=self.root, env=env,
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_packaging_preserves_xcode_sources_and_current_headers_on_rebuild(self):
        for attempt in range(2):
            result = self.build()
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertTrue((self.root / 'ios/PapercupCore.xcframework/packaged').exists())
            self.assertEqual((self.root / 'ios/PapercupCore/papercupFFI.h').read_text(),
                             '// current generated header\n')

    def test_missing_generated_header_cannot_admit_an_xcframework(self):
        result = self.build(omit_header=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'ios/PapercupCore.xcframework').exists())


if __name__ == '__main__':
    unittest.main()

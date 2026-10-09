#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Behavioral acceptance of native CI admission, retained evidence and delivery."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
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
        (self.root / 'rust-toolchain.toml').write_text('[toolchain]\nchannel = "1.99.0"\n')
        self.state = self.base / 'state'
        self.state.mkdir()
        self.identity = {'commit': 'a' * 40, 'fingerprint': 'b' * 64, 'dirty': False}
        self.native = {'xcode': 'Xcode 26.6', 'iosSDK': '26.5', 'simulator': 'SIM', 'developerDir': '/Xcode'}
        self.calls = []
        self.failure_phase = None
        self.counts = {'passedTests': 3, 'failedTests': 0, 'skippedTests': 0}
        self.args = argparse.Namespace(mode='check', distribution='app-store-connect', preflight=False, force=False,
                                       paired_ui=False, pair_payload_file=None,
                                       build_number=None, secrets_file=None,
                                       upload=False, confirm_upload=False)

    def phase(self, name, command, root, env, attempt, phases):
        self.calls.append(name)
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
            self.counts['passedTests'] = 1 if 'paired-ui.xcresult' in ' '.join(command) else 3
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

    def test_paired_and_signing_failure_logs_are_redacted_before_hashing(self):
        attempt = self.base / 'logs'
        attempt.mkdir()
        phases = []
        payload = '{"token":"private-token","server":"https://private.example"}'
        env = {'TEST_RUNNER_PAPERCUP_PAIR_PAYLOAD': payload,
               'IOS_DIST_CERT_PASSWORD': 'private-password'}

        def noisy_failure(name, command, root, env, attempt, phases):
            log = attempt / (name + '.log')
            log.write_text(payload + '\nprivate-token\nprivate-password\n')
            phases.append({'name': name, 'sha256': ci.digest(log)})
            raise RuntimeError('fixture failed')

        with patch.object(ci.mobile_ci, 'run_phase', side_effect=noisy_failure):
            with self.assertRaisesRegex(RuntimeError, 'fixture failed'):
                ci.run_phase('paired-ui', [], self.root, env, attempt, phases)
        text = (attempt / 'paired-ui.log').read_text()
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
                'mode': 'signed' if number == 1 else 'check'}))
            paths.append(attempt)
        (self.state / 'success.json').write_text(json.dumps({'attempt': str(paths[0])}))
        (self.state / 'latest.json').write_text(json.dumps({'attempt': str(paths[4])}))
        unknown = attempts / 'not-runner-owned'
        unknown.mkdir()
        ci.prune_attempts(self.state, keep=1)
        self.assertTrue(paths[0].exists())
        self.assertTrue(paths[1].exists())
        self.assertFalse(paths[2].exists())
        self.assertFalse(paths[3].exists())
        self.assertTrue(paths[4].exists())
        self.assertTrue(unknown.exists())

    def test_launch_agent_installs_checks_only_with_selected_xcode(self):
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
        self.assertEqual(installed['ProgramArguments'][-2:], ['--mode', 'check'])
        self.assertEqual(installed['StartInterval'], 1800)
        self.assertTrue(installed['RunAtLoad'])
        self.assertEqual(installed['EnvironmentVariables']['DEVELOPER_DIR'], '/Xcode26/Contents/Developer')
        self.assertEqual(launch.call_args_list[-1].args[0][1], 'bootstrap')

    def test_launch_agent_refuses_unsupported_toolchain_before_installing(self):
        with patch.object(ci.platform, 'system', return_value='Darwin'), \
                patch.object(ci, 'toolchain', side_effect=ValueError('SDK26+ required')), \
                patch.object(ci.Path, 'home', return_value=self.base), \
                patch.object(ci.subprocess, 'run') as launch:
            with self.assertRaisesRegex(ValueError, 'SDK26'):
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


if __name__ == '__main__':
    unittest.main()

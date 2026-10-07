#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Behavioral acceptance of native CI admission, retained evidence and delivery."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
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
        self.args = argparse.Namespace(mode='check', preflight=False, force=False,
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
            (attempt / 'export/app.ipa').write_bytes(b'candidate')
        if name == 'signing-install':
            Path(env['PAPERCUP_SIGNING_ENV_FILE']).write_text('{}')
        if name == 'archive-guard':
            (attempt / 'candidate-manifest.json').write_text('{}')
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
                patch.object(ci, 'output', return_value='rustc 1.99.0'), \
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

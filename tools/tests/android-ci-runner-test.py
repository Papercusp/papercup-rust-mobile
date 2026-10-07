#!/usr/bin/env python3
"""Behavioral guards for independent Android CI admission and diagnostics."""
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('android_ci', Path(__file__).resolve().parents[1] / 'android-ci.py')
ci = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci)


class AndroidCITest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.attempt = self.root / 'attempts/run'
        self.attempt.mkdir(parents=True)
        self.source = {'commit': 'a' * 40, 'fingerprint': 'b' * 64, 'dirty': False}
        self.operator = {'commit': 'c' * 40, 'root': '/prepared/operator'}
        artifact = self.attempt / 'proof.bin'
        artifact.write_bytes(b'executed proof')
        self.proof = {'source': self.source, 'operator': self.operator, 'status': 'passed',
            'week': dt.datetime.now(dt.timezone.utc).strftime('%G-%V'), 'attempt': str(self.attempt),
            'phases': [{'name': n, 'exitCode': 0} for n in ('host', 'connected', 'paired', 'verify-paired')],
            'artifacts': [{'path': 'proof.bin', 'sha256': ci.digest(artifact)}]}

    def tearDown(self):
        self.temp.cleanup()

    def save(self):
        ci.write_json(self.root / 'success.json', self.proof)

    def test_exact_success_can_be_considered_for_revalidation(self):
        self.save()
        self.assertIsNotNone(ci.cached_proof(self.root, self.source, self.operator))

    def test_source_and_counterpart_changes_refuse_old_success(self):
        self.save()
        for source, operator in ((dict(self.source, fingerprint='changed'), self.operator),
                                 (self.source, dict(self.operator, commit='d' * 40))):
            self.assertIsNone(ci.cached_proof(self.root, source, operator))

    def test_mutated_or_missing_artifact_refuses_old_success(self):
        self.save()
        artifact = self.attempt / 'proof.bin'
        artifact.write_bytes(b'replaced')
        self.assertIsNone(ci.cached_proof(self.root, self.source, self.operator))
        artifact.unlink()
        self.assertIsNone(ci.cached_proof(self.root, self.source, self.operator))

    def test_each_missing_failed_or_skipped_native_phase_refuses_admission(self):
        for phase in ('host', 'connected', 'paired', 'verify-paired'):
            original = list(self.proof['phases'])
            self.proof['phases'] = [p for p in original if p['name'] != phase]
            self.save()
            self.assertIsNone(ci.cached_proof(self.root, self.source, self.operator))
            self.proof['phases'] = [dict(p, exitCode=1) if p['name'] == phase else p for p in original]
            self.save()
            self.assertIsNone(ci.cached_proof(self.root, self.source, self.operator))
            self.proof['phases'] = original

    def test_outside_attempt_cannot_be_an_admission_artifact(self):
        self.proof['artifacts'][0]['path'] = '../../outside'
        (self.root / 'outside').write_bytes(b'executed proof')
        self.save()
        self.assertIsNone(ci.cached_proof(self.root, self.source, self.operator))

    def test_expired_proof_is_not_reused(self):
        self.proof['week'] = '2000-01'
        self.save()
        self.assertIsNone(ci.cached_proof(self.root, self.source, self.operator))

    def test_real_process_failure_records_actual_exit_and_log(self):
        phases = []
        with self.assertRaisesRegex(RuntimeError, 'unit exited 7'):
            ci.run_phase('unit', [sys.executable, '-c', "print('failure evidence'); raise SystemExit(7)"],
                         self.root, os.environ.copy(), self.attempt, phases, 10)
        self.assertEqual(phases[0]['exitCode'], 7)
        self.assertIn('failure evidence', (self.attempt / 'unit.log').read_text())
        self.assertEqual(phases[0]['sha256'], ci.digest(self.attempt / 'unit.log'))

    def test_real_process_pass_is_retained(self):
        phases = []
        ci.run_phase('unit', [sys.executable, '-c', "print('passed')"], self.root,
                     os.environ.copy(), self.attempt, phases, 10)
        self.assertEqual(phases[0]['exitCode'], 0)

    def test_preflight_failure_clears_previous_admission_and_retains_result(self):
        self.save()
        with patch.object(ci, 'source_identity', side_effect=ValueError('missing source prerequisite')):
            self.assertEqual(ci.execute(self.root, self.root, self.root), 1)
        self.assertFalse((self.root / 'success.json').exists())
        result = json.loads((self.root / 'latest.json').read_text())
        self.assertEqual(result['status'], 'failed')
        self.assertIn('missing source prerequisite', result['error'])
        self.assertTrue((Path(result['attempt']) / 'result.json').is_file())

    def test_artifact_retention_excludes_checkout_and_configuration(self):
        build = self.root / 'android/app/build'
        (build / 'outputs/apk/debug').mkdir(parents=True)
        (build / 'outputs/apk/debug/app-debug.apk').write_bytes(b'apk')
        (self.root / 'private-key').write_text('do not retain')
        artifacts = ci.collect_artifacts(self.root, self.attempt)
        names = {a['path'] for a in artifacts}
        self.assertIn('artifacts/outputs/apk/debug/app-debug.apk', names)
        self.assertNotIn('private-key', names)


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Behavioral guards for independent Android CI admission and diagnostics."""
import datetime as dt
import fcntl
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

    def test_real_android_and_shared_rust_edits_invalidate_cached_proof(self):
        paths = ('android/app/src/main/kotlin/Example.kt',
                 'crates/papercup-core/src/lib.rs')
        for path in paths:
            file = self.root / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('original source\n')

        def metadata(command, root):
            if command == ['git', 'rev-parse', 'HEAD']:
                return self.source['commit']
            if command == ['git', 'submodule', 'status', '--recursive']:
                return ''
            if command == ['git', 'status', '--porcelain']:
                return ''
            self.fail('Source-change detection must not consult commit messages: ' + repr(command))

        def tracked(command, cwd):
            if command == ['git', 'ls-files', '-z', '--cached']:
                return ('\0'.join(paths) + '\0').encode()
            if command == ['git', 'ls-files', '-z', '--others', '--exclude-standard']:
                return b''
            self.fail('Unexpected source inventory command: ' + repr(command))

        # Commit-message filters such as [skip ci] are not inputs to this
        # timer-driven detector. Exercise actual file bytes with a stable
        # commit id rather than injecting a synthetic changed fingerprint.
        with patch.object(ci, 'output', side_effect=metadata), \
                patch.object(ci.subprocess, 'check_output', side_effect=tracked):
            baseline = ci.source_identity(self.root)
            self.proof['source'] = baseline
            self.save()
            self.assertIsNotNone(ci.cached_proof(self.root, baseline, self.operator))
            for path in paths:
                with self.subTest(path=path):
                    file = self.root / path
                    file.write_text('changed source\n')
                    changed = ci.source_identity(self.root)
                    self.assertNotEqual(changed['fingerprint'], baseline['fingerprint'])
                    self.assertIsNone(ci.cached_proof(self.root, changed, self.operator))
                    file.write_text('original source\n')

    def executor_env(self):
        env = dict(os.environ, PAPERCUP_ANDROID_CI_STATE=str(self.root))
        env.pop('PAPERCUP_ANDROID_EXECUTOR_FD', None)
        env.pop('PAPERCUP_ANDROID_EXECUTOR_PID', None)
        return env

    def test_shared_executor_refuses_another_writer_before_execution(self):
        marker = self.root / 'unexpected-output'
        with (self.root / 'executor.lock').open('a+') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            run = subprocess.run([sys.executable, str(SPEC.origin), '--exclusive-command',
                sys.executable, '-c', 'from pathlib import Path; Path(' + repr(str(marker)) + ').touch()'],
                env=self.executor_env(), capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 73, run.stderr)
        self.assertFalse(marker.exists())

    def test_shared_executor_reenters_and_releases_real_process_custody(self):
        command = [sys.executable, str(SPEC.origin), '--exclusive-command',
                   sys.executable, str(SPEC.origin), '--exclusive-command',
                   sys.executable, str(SPEC.origin), '--verify-executor']
        run = subprocess.run(command, env=self.executor_env(), capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        with (self.root / 'executor.lock').open('a+') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_foreign_or_closed_inherited_descriptor_fails_closed(self):
        (self.root / 'executor.lock').touch()
        foreign = self.root / 'foreign.lock'
        with foreign.open('a+') as lock:
            env = dict(self.executor_env(), PAPERCUP_ANDROID_EXECUTOR_FD=str(lock.fileno()))
            with self.assertRaisesRegex(ValueError, 'Invalid inherited'):
                ci.inherited_executor(env)
        with self.assertRaisesRegex(ValueError, 'Invalid inherited'):
            ci.inherited_executor(env)

    def test_private_adapter_can_close_fd_without_losing_ancestor_custody(self):
        code = ('import subprocess,sys; subprocess.run([sys.executable,' +
                repr(str(SPEC.origin)) + ',"--verify-executor"],check=True)')
        run = subprocess.run([sys.executable, str(SPEC.origin), '--exclusive-command',
                              sys.executable, '-c', code], env=self.executor_env(),
                             capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)

    def test_executor_forwards_literal_separator_and_spaced_argument(self):
        run = subprocess.run([sys.executable, str(SPEC.origin), '--exclusive-command',
            sys.executable, '-c', 'import sys; assert sys.argv[1:] == ["--", "argument with spaces"]',
            '--', 'argument with spaces'], env=self.executor_env(),
            capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)

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
        admission = self.root / ci.CI_ADMISSION
        admission.parent.mkdir(parents=True)
        admission.write_text('previous candidate admission')
        with patch.object(ci, 'source_identity', side_effect=ValueError('missing source prerequisite')):
            self.assertEqual(ci.execute(self.root, self.root, self.root), 1)
        self.assertFalse((self.root / 'success.json').exists())
        self.assertFalse(admission.exists())
        result = json.loads((self.root / 'latest.json').read_text())
        self.assertEqual(result['status'], 'failed')
        self.assertIn('missing source prerequisite', result['error'])
        self.assertTrue((Path(result['attempt']) / 'result.json').is_file())

    def test_missing_required_tool_is_named_before_expensive_execution(self):
        with patch.object(ci.shutil, 'which', side_effect=lambda command, **_: None if command == 'rg' else '/usr/bin/' + command):
            with self.assertRaisesRegex(ValueError, 'Missing required Android CI tools: rg'):
                ci.required_tools({'PATH': '/usr/bin:/bin'})

    def test_complete_service_tool_set_is_admitted(self):
        with patch.object(ci.shutil, 'which', side_effect=lambda command, **_: '/usr/bin/' + command):
            ci.required_tools({'PATH': '/usr/bin:/bin'})

    def test_artifact_retention_excludes_checkout_and_configuration(self):
        build = self.root / 'android/app/build'
        (build / 'outputs/apk/debug').mkdir(parents=True)
        (build / 'outputs/apk/debug/app-debug.apk').write_bytes(b'apk')
        (self.root / 'private-key').write_text('do not retain')
        artifacts = ci.collect_artifacts(self.root, self.attempt)
        names = {a['path'] for a in artifacts}
        self.assertIn('artifacts/outputs/apk/debug/app-debug.apk', names)
        self.assertNotIn('private-key', names)

    def test_retention_preserves_current_proof_and_ignores_foreign_directories(self):
        for number in range(4):
            path = self.root / 'attempts' / f'2026010{number + 1}T000000Z-00000001'
            path.mkdir()
            ci.write_json(path / 'result.json', {'executor': 'local-systemd', 'attempt': str(path)})
        preserved = self.root / 'attempts/20260101T000000Z-00000001'
        ci.write_json(self.root / 'success.json', {'attempt': str(preserved)})
        foreign = self.root / 'attempts/unrelated'
        foreign.mkdir()
        ci.prune_attempts(self.root, keep=1)
        self.assertTrue(preserved.is_dir())
        self.assertTrue(foreign.is_dir())
        self.assertFalse((self.root / 'attempts/20260102T000000Z-00000001').exists())


if __name__ == '__main__':
    unittest.main()

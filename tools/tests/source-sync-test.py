#!/usr/bin/env python3
"""Regression coverage for cache-preserving mobile source admission."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('source_sync', ROOT / 'tools/source-sync.py')
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)
android_spec = importlib.util.spec_from_file_location('android_ci', ROOT / 'tools/android-ci.py')
android = importlib.util.module_from_spec(android_spec)
android_spec.loader.exec_module(android)


def git(root, *args):
    return subprocess.run(['git', *args], cwd=root, check=True, text=True,
                          capture_output=True)


class SourceSyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='mobile-source-sync-')
        base = Path(self.tmp.name)
        self.source = base / 'source'
        self.destination = base / 'destination'
        for root in (self.source, self.destination):
            root.mkdir()
            git(root, 'init', '-q')
            git(root, 'config', 'user.email', 'test@example.invalid')
            git(root, 'config', 'user.name', 'Source Sync Test')
        (self.source / '.gitignore').write_text('/target/\n/android/app/build/\n/ios/build/\n/node_modules/\n')
        (self.source / 'src').mkdir()
        (self.source / 'src/main.rs').write_text('fn main() {}\n')
        (self.source / 'stale.txt').write_text('fresh source\n')
        (self.destination / '.gitignore').write_text((self.source / '.gitignore').read_text())
        (self.destination / 'stale.txt').write_text('old destination\n')
        (self.destination / 'orphan.txt').write_text('destination-only tracked file\n')
        for root in (self.source, self.destination):
            git(root, 'add', '.')
            git(root, 'commit', '-qm', 'fixture')
        (self.source / 'target/debug').mkdir(parents=True)
        (self.source / 'target/debug/cache').write_bytes(b'ignored source cache')
        # The original incident copied gigabytes of ignored Android output.
        # A sparse file exercises its logical size without consuming that space.
        with (self.source / 'target/ignored-eight-gib').open('wb') as stream:
            stream.truncate(8 * 1024**3)
        (self.source / 'android/app/build').mkdir(parents=True)
        (self.source / 'android/app/build/generated.bin').write_bytes(b'ignored android output')
        (self.destination / 'target/debug').mkdir(parents=True)
        (self.destination / 'target/debug/cache').write_bytes(b'preserve destination cache')
        (self.destination / 'ios/build').mkdir(parents=True)
        (self.destination / 'ios/build/DerivedData').write_bytes(b'preserve xcode cache')
        for root in (self.source, self.destination):
            for name in ('node_modules/cache', 'android/app/build/cache'):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('preserve ' + str(root))
        self.addCleanup(self.tmp.cleanup)

    def test_sync_preserves_ignored_caches_removes_only_stale_tracked_and_verifies_digest(self):
        result = sync.sync(self.source, self.destination, max_bytes=10000, max_files=100)
        self.assertEqual(result['verifiedIdentity'], sync.mobile_ci.source_identity(self.source))
        self.assertEqual(result['verifiedIdentity'], sync.mobile_ci.source_identity(self.destination))
        self.assertFalse(result['verifiedIdentity']['dirty'])
        self.assertEqual((self.destination / 'src/main.rs').read_text(), 'fn main() {}\n')
        self.assertEqual((self.destination / 'target/debug/cache').read_bytes(), b'preserve destination cache')
        self.assertEqual((self.destination / 'ios/build/DerivedData').read_bytes(), b'preserve xcode cache')
        self.assertEqual((self.destination / 'stale.txt').read_text(), 'fresh source\n')
        self.assertFalse((self.destination / 'orphan.txt').exists())
        self.assertFalse((self.destination / 'android/app/build/generated.bin').exists())
        for name in ('node_modules/cache', 'android/app/build/cache'):
            self.assertEqual((self.destination / name).read_text(), 'preserve ' + str(self.destination))
        # A second refresh is clean and leaves cache inode/content intact.
        cache = self.destination / 'target/debug/cache'
        inode = cache.stat().st_ino
        sync.sync(self.source, self.destination, max_bytes=10000, max_files=100)
        self.assertEqual(cache.stat().st_ino, inode)

    def test_untracked_destination_collision_is_refused_without_mutation(self):
        (self.destination / 'src').mkdir(exist_ok=True)
        (self.destination / 'src/main.rs').write_text('untracked collision\n')
        before = (self.destination / 'src/main.rs').read_bytes()
        with self.assertRaises(sync.SyncRefused):
            sync.sync(self.source, self.destination, max_bytes=10000, max_files=100)
        self.assertEqual((self.destination / 'src/main.rs').read_bytes(), before)

    def test_budget_refusal_happens_before_destination_mutation(self):
        before = (self.destination / 'stale.txt').read_bytes()
        with self.assertRaises(sync.SyncRefused):
            sync.sync(self.source, self.destination, max_bytes=1, max_files=100)
        self.assertEqual((self.destination / 'stale.txt').read_bytes(), before)
        self.assertTrue((self.destination / 'target/debug/cache').exists())

    def test_git_metadata_bytes_are_admitted_before_any_source_change(self):
        files, _ = sync.inventory(self.source)
        source_bytes = sync._size(self.source, files)
        with self.assertRaisesRegex(sync.SyncRefused, 'plus Git metadata'):
            sync.sync(self.source, self.destination, max_bytes=source_bytes + 1, max_files=100)
        self.assertTrue((self.destination / 'orphan.txt').exists())

    def test_dry_run_keeps_destination_source_and_git_identity(self):
        before = sync.mobile_ci.source_identity(self.destination)
        report = sync.sync(self.source, self.destination, max_bytes=10000, max_files=100, dry_run=True)
        self.assertEqual(sync.mobile_ci.source_identity(self.destination), before)
        self.assertNotIn('verifiedIdentity', report)
        self.assertGreater(report['bytesIncludingGit'], report['bytes'])

    def test_source_motion_and_private_config_mismatch_refuse_before_copy(self):
        original = sync.mobile_ci.source_identity
        calls = []
        def moving(root):
            calls.append(root)
            if len(calls) == 2:
                (self.source / 'stale.txt').write_text('changed during admission')
            return original(root)
        with patch.object(sync.mobile_ci, 'source_identity', side_effect=moving):
            with self.assertRaisesRegex(sync.SyncRefused, 'changed during preflight'):
                sync.sync(self.source, self.destination, max_bytes=10000, max_files=100)
        (self.source / 'stale.txt').write_text('fresh source\n')
        # Force the private-file case into the ignored input used by real CI.
        for root in (self.source, self.destination):
            with (root / '.gitignore').open('a') as stream:
                stream.write('/android/app/google-services.json\n')
            git(root, 'commit', '-qam', 'ignore private config')
        config = self.destination / 'android/app/google-services.json'
        config.write_text('private configuration')
        with self.assertRaisesRegex(sync.SyncRefused, 'private Firebase'):
            sync.sync(self.source, self.destination, max_bytes=10000, max_files=100)
        self.assertTrue((self.destination / 'orphan.txt').exists())

    def test_closed_progress_pipe_does_not_skip_child_or_verdict(self):
        attempt = Path(self.tmp.name) / 'attempt'
        attempt.mkdir()
        program = textwrap.dedent('''
            import importlib.util, json, os, sys
            from pathlib import Path
            spec = importlib.util.spec_from_file_location('ci', sys.argv[1])
            ci = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(ci)
            attempt = Path(sys.argv[2])
            phases = []
            ci.run_phase('closed', [sys.executable, '-c', 'print("retained child output")'],
                         attempt, os.environ.copy(), attempt, phases)
            ci.status('verdict retained')
            (attempt / 'verdict.json').write_text(json.dumps(phases))
        ''')
        read_fd, write_fd = os.pipe()
        os.close(read_fd)
        try:
            result = subprocess.run([sys.executable, '-c', program, str(ROOT / 'tools/android-ci.py'),
                                     str(attempt)], stdout=write_fd, stderr=subprocess.PIPE, timeout=20)
        finally:
            os.close(write_fd)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        phases = json.loads((attempt / 'verdict.json').read_text())
        self.assertEqual(phases[0]['exitCode'], 0)
        self.assertEqual((attempt / 'closed.log').read_text(), 'retained child output\n')

    def test_ignored_collision_refused_before_tracked_deletion(self):
        (self.source / 'target/tracked').write_text('new tracked source')
        git(self.source, 'add', '-f', 'target/tracked')
        git(self.source, 'commit', '-qm', 'track new source path')
        (self.destination / 'target/tracked').write_text('existing private output')
        with self.assertRaisesRegex(sync.SyncRefused, 'collision'):
            sync.sync(self.source, self.destination, max_bytes=10000, max_files=100)
        self.assertEqual((self.destination / 'target/tracked').read_text(), 'existing private output')
        self.assertTrue((self.destination / 'orphan.txt').exists())

    def test_dirty_source_destination_and_expired_budget_refuse_before_mutation(self):
        for side in (self.source, self.destination):
            path = side / 'stale.txt'
            original = path.read_bytes()
            path.write_text('local edit')
            with self.assertRaises(sync.SyncRefused):
                sync.sync(self.source, self.destination, max_bytes=10000, max_files=100)
            path.write_bytes(original)
        for kwargs in ({'timeout': 0}, {'max_files': 1}, {'max_bytes': 0}):
            options = dict(max_bytes=10000, max_files=100, timeout=600)
            options.update(kwargs)
            with self.assertRaises(sync.SyncRefused):
                sync.sync(self.source, self.destination, **options)
        self.assertTrue((self.destination / 'orphan.txt').exists())

    def test_native_shared_custody_refuses_sync_and_sync_exclusive_refuses_execution(self):
        lock_path = self.destination / '.git/papercup-source.lock'
        with sync.mobile_ci.source_custody(self.destination):
            inode = lock_path.stat().st_ino
            with self.assertRaisesRegex(ValueError, 'custody is held'):
                sync.sync(self.source, self.destination, max_bytes=10000, max_files=100)
        with sync.mobile_ci.source_custody(self.destination, exclusive=True):
            with self.assertRaisesRegex(ValueError, 'custody is held'):
                with sync.mobile_ci.source_custody(self.destination):
                    self.fail('native execution entered during source transfer')
        sync.sync(self.source, self.destination, max_bytes=10000, max_files=100)
        self.assertEqual(lock_path.stat().st_ino, inode)

    def test_initialized_submodule_source_and_caches_preserve_exact_identity(self):
        module = Path(self.tmp.name) / 'module'
        module.mkdir()
        git(module, 'init', '-q')
        git(module, 'config', 'user.email', 'test@example.invalid')
        git(module, 'config', 'user.name', 'Source Sync Test')
        (module / 'lib.txt').write_text('version one')
        (module / '.gitignore').write_text('/target/\n')
        git(module, 'add', '.')
        git(module, 'commit', '-qm', 'module initial')
        for root in (self.source, self.destination):
            git(root, '-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', str(module), 'libs/module')
            git(root, 'commit', '-qam', 'add module')
        (module / 'lib.txt').write_text('version two')
        git(module, 'commit', '-qam', 'module update')
        git(self.source / 'libs/module', 'fetch', '-q')
        git(self.source / 'libs/module', 'merge', '--ff-only', 'FETCH_HEAD')
        git(self.source, 'commit', '-qam', 'update module')
        cache = self.destination / 'libs/module/target/cache'
        cache.parent.mkdir()
        cache.write_text('retained nested Rust cache')
        sync.sync(self.source, self.destination, max_bytes=10000, max_files=100)
        self.assertEqual((self.destination / 'libs/module/lib.txt').read_text(), 'version two')
        self.assertEqual(cache.read_text(), 'retained nested Rust cache')
        self.assertEqual(sync.mobile_ci.source_identity(self.source), sync.mobile_ci.source_identity(self.destination))


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Behavioral guards for independent Android CI admission and diagnostics."""
import datetime as dt
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('android_ci', Path(__file__).resolve().parents[1] / 'android-ci.py')
ci = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci)


class AndroidCITest(unittest.TestCase):
    def setUp(self):
        evidence = Path(SPEC.origin).parents[1] / 'android/app/build/ci-evidence'
        evidence.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='ci-runner-fixtures.', dir=evidence)
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

    def test_fixture_suite_keeps_loaded_source_across_mid_run_edits(self):
        project = Path(SPEC.origin).parents[1]
        source = (project / 'tools/tests/run-android-checks-test.sh').read_text()
        root_line = 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"'
        source = source.replace(root_line, 'ROOT=' + str(project), 1)
        source = source.replace('set -euo pipefail\n',
                                'set -euo pipefail\nprintf "snapshot-ready\\n"\nread -r snapshot_gate\n', 1)
        control = source.replace('run_android_fixture_suite() {\n', '', 1)
        control = control.removesuffix('}\nrun_android_fixture_suite "$@"\n')
        for name, code in [('loaded-suite', source), ('streaming-control', control)]:
            with self.subTest(name=name):
                script = self.root / (name + '.sh')
                script.write_text(code)
                process = subprocess.Popen(['bash', str(script), 'toolchain'],
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, text=True)
                try:
                    self.assertTrue(select.select([process.stdout], [], [], 30)[0], 'suite did not reach owned gate')
                    self.assertEqual(process.stdout.readline(), 'snapshot-ready\n')
                    # Preserve the inode and byte positions, like an editor's
                    # in-place rewrite, but change a later unread shell token.
                    needle = 'if [[ "$suite" == all || "$suite" == toolchain ]]; then'
                    script.write_text(code.replace(needle, ')' + ' ' * (len(needle) - 1), 1))
                    stdout, stderr = process.communicate('continue\n', timeout=30)
                    if name == 'loaded-suite':
                        self.assertEqual(process.returncode, 0, (stdout, stderr))
                        self.assertIn('Android Rust toolchain preflight: six discovery and failure controls passed', stdout)
                    else:
                        self.assertNotEqual(process.returncode, 0, (stdout, stderr))
                        self.assertIn('syntax error', stderr)
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.communicate()

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

    def java_environment(self):
        env = self.executor_env()
        env['JAVA_HOME'] = ci.output(['bash', 'tools/build-scripts/resolve-java-home.sh'], ci.ROOT, env)
        resolver = self.root / 'tools/build-scripts/resolve-java-home.sh'
        resolver.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ci.ROOT / 'tools/build-scripts/resolve-java-home.sh', resolver)
        return env

    def test_maintained_private_runtime_reparents_actual_jvm_temp_before_build(self):
        env = self.java_environment()
        operator = Path(env.get('PAPERCUP_PAPERCUSP_ROOT', str(ci.ROOT.parent / 'papercusp'))).resolve()
        wrapper = operator / 'scripts/with-test-pg.mjs'
        self.assertTrue(wrapper.is_file(), 'Prepare the maintained operator test-runtime wrapper')
        for relative in ('tools/android-ci.py', 'tools/build-scripts/build-android.sh'):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ci.ROOT / relative, destination)
        code = textwrap.dedent('''
            import json,os,re,subprocess,sys
            from pathlib import Path
            root=Path(sys.argv[1]); ci=root/'tools/android-ci.py'
            java=str(Path(os.environ['JAVA_HOME'])/'bin/java')
            def probe(env):
                run=subprocess.run([java,'-XshowSettings:properties','-version'],env=env,
                                   text=True,capture_output=True,check=True)
                return re.search(r'^\\s*java.io.tmpdir = (.+)$',run.stderr,re.MULTILINE)[1]
            before=probe(os.environ)
            expected=str(Path(os.environ['TMPDIR']).resolve())
            print('ANDROID_TMP_PROBE '+json.dumps({'before':before,'expected':expected}),flush=True)
            assert before != expected, 'maintained wrapper did not exercise reparenting'
            refusal=subprocess.run([sys.executable,str(ci),'--verify-build-storage'],
                cwd=root,text=True,capture_output=True)
            assert refusal.returncode != 0
            assert 'Selected Android JVM does not use' in refusal.stderr
            diagnostic=next(json.loads(line)['temporaryDirectoryCheck']
                for line in refusal.stderr.splitlines() if line.startswith('{'))
            assert diagnostic['expectedDirectory'] == expected
            assert diagnostic['selectedDirectory'] == before
            assert diagnostic['javaExitCode'] == 0 and not diagnostic['matched']
            fixed=dict(os.environ)
            fixed['JAVA_TOOL_OPTIONS']=subprocess.check_output([sys.executable,str(ci),
                '--verify-executor','--java-tool-options'],text=True,cwd=root).strip()
            after=probe(fixed)
            assert after == expected and '-Dguard.option=preserved' in fixed['JAVA_TOOL_OPTIONS']
            # Execute the real build entry. An absent fixture SDK stops it only
            # AFTER its actual JVM/capacity preflight, before any Cargo/Gradle.
            build_env=dict(os.environ,ANDROID_HOME=str(root/'absent-sdk'),
                           ANDROID_SDK_ROOT=str(root/'absent-sdk'))
            build=subprocess.run(['bash',str(root/'tools/build-scripts/build-android.sh'),'debug'],
                cwd=root,env=build_env,text=True,capture_output=True)
            assert 'Android SDK not found' in build.stderr, build.stderr
            diagnostics=[json.loads(line)['temporaryDirectoryCheck']
                for line in build.stderr.splitlines() if line.startswith('{')
                and 'temporaryDirectoryCheck' in line]
            assert len(diagnostics) == 1 and diagnostics[0]['matched'], build.stderr
            assert diagnostics[0]['selectedDirectory'] == expected
            # An explicit JVM override is a different cause. Refuse it and
            # retain the ACTUAL selected property, without dumping options.
            override=dict(fixed,_JAVA_OPTIONS='-Djava.io.tmpdir="'+before+'"')
            refusal=subprocess.run([sys.executable,str(ci),'--verify-build-storage'],
                cwd=root,env=override,text=True,capture_output=True)
            assert refusal.returncode != 0
            diagnostic=next(json.loads(line)['temporaryDirectoryCheck']
                for line in refusal.stderr.splitlines() if line.startswith('{'))
            assert diagnostic['selectedDirectory'] == before and not diagnostic['matched']
            print('ANDROID_TMP_PROBE '+json.dumps({'after':after,'privateTemporaryDirectory':expected,
                              'overrideRefused':True}),flush=True)
        ''')
        env['JAVA_TOOL_OPTIONS'] = '-Dguard.option=preserved'
        command = [sys.executable, str(SPEC.origin), '--exclusive-command',
                   'node', str(wrapper), '--isolated-runtime=operator-api', '--',
                   sys.executable, '-c', code, str(self.root)]
        run = subprocess.run(command, cwd=ci.ROOT, env=env,
                             capture_output=True, text=True, timeout=120)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        records = [json.loads(line.removeprefix('ANDROID_TMP_PROBE '))
                   for line in run.stdout.splitlines() if line.startswith('ANDROID_TMP_PROBE ')]
        self.assertEqual(len(records), 2, run.stdout)
        self.assertEqual(records[0]['expected'], records[1]['after'])
        self.assertTrue(records[1]['overrideRefused'])
        self.assertFalse(Path(records[1]['privateTemporaryDirectory']).exists())
        self.assertEqual(list(self.root.glob('command-tmp-*')), [])
        with (self.root / 'executor.lock').open('a+') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        print(json.dumps({'privateRuntimeJvmTempGuard': records, 'cleanupVerified': True,
                          'wrapper': str(wrapper), 'wrapperSha256': ci.digest(wrapper)}), flush=True)

    def test_generated_kotlin_errors_do_not_dirty_source_identity(self):
        subprocess.run(['git', 'init', '--quiet', str(self.root)], check=True)
        (self.root / '.gitignore').write_bytes((ci.ROOT / '.gitignore').read_bytes())
        # Tracked entries, rather than a commit, are enough to verify the
        # actual ignore policy used by source_identity's untracked inventory.
        subprocess.run(['git', 'add', '.gitignore'], cwd=self.root, check=True)
        generated = self.root / 'android/.kotlin/errors/errors-current.log'
        generated.parent.mkdir(parents=True)
        generated.write_text('generated Kotlin daemon diagnostic')
        source = self.root / 'android/app/src/main/kotlin/Meaningful.kt'
        source.parent.mkdir(parents=True)
        source.write_text('meaningful source')
        untracked = subprocess.check_output(['git', 'ls-files', '-z', '--others', '--exclude-standard'],
                                            cwd=self.root).split(b'\0')
        self.assertNotIn(b'android/.kotlin/errors/errors-current.log', untracked)
        self.assertIn(b'android/app/src/main/kotlin/Meaningful.kt', untracked)

    def test_executor_temp_refuses_foreign_directory_and_requires_verified_custody(self):
        with tempfile.TemporaryDirectory(dir=self.root.parent, prefix='foreign-runtime-') as name:
            foreign = Path(name)
            env = dict(self.executor_env(), TMPDIR=str(foreign))
            with self.assertRaisesRegex(ValueError, 'must belong to its owned state or private runtime'):
                ci.executor_temporary_directory(env)
            env.update(HOME=str(foreign / 'home'), PAPERCUSP_HOME=str(foreign / 'home/.papercusp'),
                       PAPERCUSP_WORKSPACE_ID='test-runtime-0123456789ab')
            (foreign / 'home').mkdir()
            (foreign / 'tmp').mkdir()
            env['TMPDIR'] = str(foreign / 'tmp')
            with self.assertRaisesRegex(ValueError, 'must belong to its owned state or private runtime'):
                ci.executor_temporary_directory(env)
        run = subprocess.run([sys.executable, str(SPEC.origin), '--verify-executor', '--java-tool-options'],
                             env=self.executor_env(), capture_output=True, text=True, timeout=10)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn('Inherited Android executor custody is required', run.stderr)

    def test_real_bundletool_packaging_uses_owned_jvm_temp_and_cleans_both_exits(self):
        cache = Path(os.environ.get('GRADLE_USER_HOME', str(Path.home() / '.gradle'))) / 'caches/modules-2/files-2.1'
        bundletool = sorted((cache / 'com.android.tools.build/bundletool').glob('*/*/*.jar'))
        guava = sorted((cache / 'com.google.guava/guava').glob('*/*/*.jar'))
        self.assertTrue(bundletool and guava, 'Prepare the maintained Android Gradle dependencies before this guard')
        classpath = os.pathsep.join(map(str, (bundletool[-1], guava[-1])))
        source = self.root / 'BundleTempGuard.java'
        source.write_text('''
import java.nio.file.*;
import java.util.zip.*;
import com.android.tools.build.bundletool.io.TempDirectory;
class BundleTempGuard {
    public static void main(String[] args) throws Exception {
        try (TempDirectory temporary = new TempDirectory("bundletool-guard-")) {
            Path archive = temporary.getPath().resolve("module.zip");
            try (ZipOutputStream zip = new ZipOutputStream(Files.newOutputStream(archive))) {
                zip.putNextEntry(new ZipEntry("base/payload"));
                zip.write("real BundleTool temporary packaging".getBytes());
                zip.closeEntry();
            }
            try (ZipFile zip = new ZipFile(archive.toFile())) {
                if (zip.getEntry("base/payload") == null) throw new AssertionError("missing ZIP entry");
            }
            if (!"preserved".equals(System.getProperty("guard.option"))) throw new AssertionError("lost JVM option");
            System.out.println(System.getProperty("java.io.tmpdir"));
            System.out.println(temporary.getPath());
            System.exit(Integer.parseInt(args[0]));
        }
    }
}
''')
        foreign = self.root / 'unusable foreign JVM temp'
        foreign.write_text('not a directory')
        env = self.java_environment()
        env.update(TMPDIR=str(self.root), JAVA_TOOL_OPTIONS='-Dguard.option=preserved -Djava.io.tmpdir="' + str(foreign) + '"')
        java = [str(Path(env['JAVA_HOME']) / 'bin/java'), '--class-path', classpath, str(source)]
        # A real JVM/BundleTool negative control: shell TMPDIR cannot override
        # Java's selected parent. No release, signing input or shared APK is used.
        baseline = subprocess.run(java + ['0'], env=env, capture_output=True, text=True, timeout=60)
        self.assertNotEqual(baseline.returncode, 0, baseline.stdout)
        self.assertIn('Not a directory', baseline.stderr)
        for code in (0, 7):
            command = [sys.executable, str(SPEC.origin), '--exclusive-command',
                       sys.executable, str(SPEC.origin), '--exclusive-command', *java, str(code)]
            run = subprocess.run(command, env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(run.returncode, code, run.stderr)
            lines = [line for line in run.stdout.splitlines() if not line.startswith('{')]
            temporary, bundle = map(Path, lines)
            self.assertEqual(temporary.parent, self.root)
            self.assertTrue(temporary.name.startswith('command-tmp-'))
            self.assertEqual(bundle.parent, temporary)
            self.assertFalse(temporary.exists())
            self.assertFalse(bundle.exists())
            self.assertTrue(foreign.is_file())
            with (self.root / 'executor.lock').open('a+') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_build_storage_measures_both_destinations_and_combines_shared_capacity(self):
        temporary = self.root / 'owned JVM temp with spaces'
        temporary.mkdir()
        env = self.java_environment()
        ci.owned_temporary_environment(env, temporary)
        build = self.root / 'android/app/build'
        module = build / 'intermediates/module_bundle/release/base.zip'
        module.parent.mkdir(parents=True)
        module.write_bytes(b'module input')
        gib = 1024**3
        for shared, temp_free, build_free, expected in (
                (False, gib, gib, True), (False, gib - 1, 4 * gib, False),
                (False, 4 * gib, gib - 1, False),
                (True, 2 * gib - 1, 2 * gib - 1, False), (True, 2 * gib, 2 * gib, True)):
            calls = []

            def capacity(path):
                calls.append(path)
                self.assertIn(path, (temporary, build))
                return {'device': 1 if shared or path == temporary else 2,
                        'availableBytes': temp_free if path == temporary else build_free}

            with self.subTest(shared=shared, temp_free=temp_free, build_free=build_free), \
                    patch.object(ci, 'filesystem_capacity', side_effect=capacity):
                if expected:
                    report = ci.verify_build_storage(self.root, env)
                    self.assertEqual(report['jvmTemporaryDirectory'], str(temporary))
                    self.assertEqual(report['moduleInputBytes'], len(b'module input'))
                    self.assertEqual(len(report['filesystems']), 1 if shared else 2)
                else:
                    with self.assertRaisesRegex(ValueError, 'Insufficient Android build or JVM temporary'):
                        ci.verify_build_storage(self.root, env)
                self.assertEqual(calls, [temporary, build])

    def test_build_storage_refuses_actual_jvm_temp_mismatch(self):
        temporary = self.root / 'owned tmp'
        temporary.mkdir()
        env = self.java_environment()
        env.update(TMPDIR=str(temporary), JAVA_TOOL_OPTIONS='-Djava.io.tmpdir="' + str(self.root) + '"')
        with self.assertRaisesRegex(ValueError, 'JVM does not use the owned'):
            ci.verify_build_storage(self.root, env)

    def test_producer_preflight_refuses_before_execution_and_cleans_custody(self):
        env = self.java_environment()
        builder = self.root / 'tools/build-scripts/build-android.sh'
        shutil.copyfile(ci.ROOT / 'tools/build-scripts/build-android.sh', builder)
        # Execute the real build entry with a measured zero-capacity oracle;
        # no cargo, Gradle task or release secret is needed to reach this guard.
        launcher = self.root / 'tools/android-ci.py'
        launcher.write_text('import importlib.util\nfrom pathlib import Path\n'
            's=importlib.util.spec_from_file_location("ci",' + repr(str(SPEC.origin)) + ')\n'
            'ci=importlib.util.module_from_spec(s); s.loader.exec_module(ci)\n'
            'ci.ROOT=Path(' + repr(str(self.root)) + ')\n'
            'ci.filesystem_capacity=lambda p: {"device":1,"availableBytes":0}\n'
            'raise SystemExit(ci.main())\n')
        outputs = [self.root / ('android/app/build/' + name) for name in (
            'outputs/apk/release/app-release.apk', 'outputs/bundle/release/app-release.aab',
            'outputs/papercusp-release-provenance.json')]
        jni = self.root / 'android/app/src/main/jniLibs/arm64-v8a/libpapercup.so'
        for file in [*outputs, jni]:
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b'preceding output')
        env['PAPERCUP_RELEASE_VERSION'] = 'fixture-release'
        run = subprocess.run([sys.executable, str(SPEC.origin), '--exclusive-command',
                              'bash', str(builder), 'release'], env=env,
                             capture_output=True, text=True, timeout=30)
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertIn('Insufficient Android build or JVM temporary', run.stderr)
        for file in [*outputs, jni]:
            self.assertEqual(file.read_bytes(), b'preceding output')
        self.assertEqual(list(self.root.glob('command-tmp-*')), [])
        with (self.root / 'executor.lock').open('a+') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)

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

    def test_preflight_measures_owned_avd_filesystem_and_refuses_its_shortfall(self):
        state = self.root / 'owned state with spaces'
        state.mkdir()
        foreign = self.root / 'foreign avd filesystem'
        foreign.mkdir()
        sdk = self.root / 'sdk'
        image = sdk / 'system-images/android-36/google_apis_ps16k/x86_64/system.img'
        image.parent.mkdir(parents=True)
        image.touch()
        runner = self.root / 'tools/run-android-checks.sh'
        runner.parent.mkdir()
        runner.write_bytes((Path(SPEC.origin).parent / 'run-android-checks.sh').read_bytes())
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        df = bin_dir / 'df'
        real_run_phase = ci.run_phase

        def phase(name, command, root, env, attempt, phases, timeout=5400):
            if name == 'avd-space-preflight':
                return real_run_phase(name, command, root, env, attempt, phases, timeout)
            phases.append({'name': name, 'exitCode': 0})

        def metadata(command, root, env=None):
            if command == ['node', '--version']:
                return 'v25.0.0'
            if command == ['git', 'rev-parse', 'HEAD']:
                return self.operator['commit']
            return '/prepared/jdk'

        # The two mounts have opposite capacities. A default/inherited AVD
        # lookup must fail the positive control and pass the negative control.
        for owned_kb, foreign_kb, expected in ((10 * 1024**2, 1, 0), (1, 10 * 1024**2, 1)):
            with self.subTest(owned_kb=owned_kb):
                df.write_text('#!/usr/bin/env python3\nimport sys\n'
                    'available = ' + str(owned_kb) + ' if sys.argv[-1] == ' + repr(str(state))
                    + ' else ' + str(foreign_kb) + '\n'
                    'print("Filesystem 1024-blocks Used Available Capacity Mounted on")\n'
                    'print("fixture 0 0", available, "0% fixture")\n')
                df.chmod(0o755)
                with patch.dict(os.environ, {'ANDROID_AVD_HOME': str(foreign),
                        'ANDROID_HOME': str(sdk), 'PATH': str(bin_dir) + ':' + os.environ['PATH']}), \
                        patch.object(ci, 'required_tools'), \
                        patch.object(ci, 'source_identity', return_value=self.source), \
                        patch.object(ci, 'output', side_effect=metadata), \
                        patch.object(ci, 'run_phase', side_effect=phase), \
                        patch.object(ci.os, 'access', return_value=True):
                    self.assertEqual(ci.execute(self.root, self.root, state, preflight_only=True), expected)
                result = json.loads((state / 'latest.json').read_text())
                report = json.loads((Path(result['attempt']) / 'avd-space.txt').read_text())
                self.assertEqual(report['avdRoot'], str(state))
                self.assertEqual(report['availableBytes'], owned_kb * 1024)
                self.assertEqual(report['sufficient'], expected == 0)
                self.assertEqual(result['status'], 'preflight-passed' if expected == 0 else 'failed')
                self.assertFalse((state / 'success.json').exists())
                self.assertFalse((self.root / ci.CI_ADMISSION).exists())

    def test_children_use_owned_temporary_filesystem_and_cleanup_after_failure(self):
        sdk = self.root / 'sdk'
        image = sdk / 'system-images/android-36/google_apis_ps16k/x86_64/system.img'
        image.parent.mkdir(parents=True)
        image.touch()
        foreign = self.root / 'unusable inherited tmp'
        foreign.write_text('not a directory')
        real_run_phase = ci.run_phase

        def metadata(command, root, env=None):
            if command == ['node', '--version']:
                return 'v25.0.0'
            if command == ['git', 'rev-parse', 'HEAD']:
                return self.operator['commit']
            return '/prepared/jdk'

        def phase(name, command, root, env, attempt, phases, timeout=5400):
            if name in ('rust-preflight', 'host'):
                code = ('import pathlib,tempfile; '
                        'p=pathlib.Path(tempfile.mkdtemp()); '
                        '(p/"fixture").write_text("executed child fixture"); '
                        'print(p); raise SystemExit(' + ('7' if name == 'host' else '0') + ')')
                return real_run_phase(name, [sys.executable, '-c', code], root,
                                      env, attempt, phases, timeout)
            phases.append({'name': name, 'exitCode': 0})

        for preflight_only, expected in ((True, 0), (False, 1)):
            with self.subTest(preflight_only=preflight_only), \
                    patch.dict(os.environ, {'ANDROID_HOME': str(sdk), 'TMPDIR': str(foreign)}), \
                    patch.object(ci, 'required_tools'), \
                    patch.object(ci, 'source_identity', return_value=self.source), \
                    patch.object(ci, 'output', side_effect=metadata), \
                    patch.object(ci, 'run_phase', side_effect=phase), \
                    patch.object(ci.os, 'access', return_value=True):
                self.assertEqual(ci.execute(self.root, self.root, self.root,
                                            preflight_only=preflight_only), expected)
                result = json.loads((self.root / 'latest.json').read_text())
                attempt = Path(result['attempt'])
                for name in ('rust-preflight',) if preflight_only else ('rust-preflight', 'host'):
                    used = Path((attempt / (name + '.log')).read_text().strip())
                    self.assertEqual(used.parent, attempt / 'tmp')
                    self.assertFalse(used.exists())
                self.assertTrue(result['temporaryCleanupVerified'])
                self.assertFalse((attempt / 'tmp').exists())
                self.assertFalse((self.root / 'success.json').exists())
                self.assertFalse((self.root / ci.CI_ADMISSION).exists())
                self.assertTrue(foreign.is_file())

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

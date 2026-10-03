#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Write or verify the one publishable Android release candidate contract.
set -euo pipefail

REPO_ROOT="${PAPERCUP_MOBILE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
MANIFEST_REL="android/app/build/outputs/papercusp-release-provenance.json"
RECORD_REL="android/app/build/outputs/RELEASE-CANDIDATE.md"
APK_REL="android/app/build/outputs/apk/release/app-release.apk"
AAB_REL="android/app/build/outputs/bundle/release/app-release.aab"
SOURCE_REL="android/app/build/outputs/papercusp-mobile-source.tar.gz"
MANIFEST="$REPO_ROOT/$MANIFEST_REL"
RECORD="$REPO_ROOT/$RECORD_REL"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

version_code_for() {
    local version="$1" major minor patch version_code
    [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)([-+].+)?$ ]] \
        || die "release version must be MAJOR.MINOR.PATCH (got $version)"
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    version_code=$((10#$major * 10000 + 10#$minor * 100 + 10#$patch))
    (( version_code > 0 && version_code <= 2100000000 )) \
        || die "derived Android versionCode must be between 1 and 2100000000 (got $version_code)"
    printf '%s\n' "$version_code"
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

source_commit() {
    git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null \
        || die "$REPO_ROOT is not a git checkout"
}

assert_clean_source() {
    local dirty
    dirty="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)"
    [[ -z "$dirty" ]] || {
        echo "ERROR: Android release provenance requires a clean source tree; these paths are not in HEAD:" >&2
        printf '%s\n' "$dirty" >&2
        exit 1
    }
}

# Export only committed files, including each recursively pinned submodule.
# This is the project's source contribution, not third-party license clearance
# or proof that a recipient can retrieve it from a published location.
source_archive() {
    local action="$1" commit="$2"
    REPO_ROOT="$REPO_ROOT" SOURCE_REL="$SOURCE_REL" python3 - "$action" "$commit" <<'PY'
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tarfile
import tempfile

action, commit = sys.argv[1:]
root = Path(os.environ['REPO_ROOT']).resolve()
output = root / os.environ['SOURCE_REL']
prefix = 'papercusp-mobile-source/'
expected, repositories = {}, []

def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args])

def safe_path(name):
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or not path.parts:
        raise SystemExit(f'Unsafe source path: {name}')
    return path

def collect(repo, revision, relative=''):
    if not repo.is_dir() or Path(git(repo, 'rev-parse', '--show-toplevel').decode().strip()).resolve() != repo:
        raise SystemExit(f'Source repository is not initialized: {relative or "."}')
    if git(repo, 'rev-parse', 'HEAD').decode().strip() != revision:
        raise SystemExit(f'Source repository differs from its gitlink: {relative or "."}')
    if git(repo, 'status', '--porcelain', '--untracked-files=normal').strip():
        raise SystemExit(f'Source repository is dirty: {relative or "."}')
    repositories.append({'path': relative or '.', 'commit': revision})
    objects = {}
    children = []
    for row in git(repo, 'ls-tree', '-rz', '--full-tree', revision).split(b'\0'):
        if not row:
            continue
        header, name = row.split(b'\t', 1)
        mode, kind, oid = header.decode().split()
        name = name.decode()
        safe_path(name)
        if kind == 'commit' and mode == '160000':
            children.append((name, oid))
        elif kind == 'blob':
            objects[name] = (mode, oid)
        else:
            raise SystemExit(f'Unsupported source entry: {name}')
    object_format = git(repo, 'rev-parse', '--show-object-format').decode().strip()
    seen = set()
    with tarfile.open(fileobj=io.BytesIO(git(repo, 'archive', '--format=tar', revision))) as archive:
        for member in archive:
            if member.isdir():
                continue
            safe_path(member.name)
            if member.name not in objects or member.name in seen:
                raise SystemExit(f'Unexpected source archive entry: {member.name}')
            seen.add(member.name)
            mode, oid = objects[member.name]
            if member.issym() and mode == '120000':
                data = member.linkname.encode()
            elif member.isfile() and mode in ('100644', '100755'):
                data = archive.extractfile(member).read()
            else:
                raise SystemExit(f'Source entry type mismatch: {member.name}')
            blob = b'blob ' + str(len(data)).encode() + b'\0' + data
            if hashlib.new(object_format, blob).hexdigest() != oid:
                raise SystemExit(f'Source archive differs from committed bytes: {member.name}')
            full = prefix + (relative + '/' if relative else '') + member.name
            expected[full] = (member, data)
    if seen != set(objects):
        raise SystemExit('Source archive omitted committed files (check export-ignore attributes)')
    for name, oid in children:
        child = (repo / name).resolve()
        if not child.is_relative_to(root):
            raise SystemExit(f'Submodule escapes source root: {name}')
        collect(child, oid, (relative + '/' if relative else '') + name)

collect(root, commit)
metadata_name = prefix + 'SOURCE-PROVENANCE.json'
if metadata_name in expected:
    raise SystemExit('SOURCE-PROVENANCE.json is reserved for generated source identity')
metadata = (json.dumps({'schemaVersion': 1, 'sourceCommit': commit,
                       'repositories': repositories}, sort_keys=True, indent=2) + '\n').encode()
info = tarfile.TarInfo(metadata_name)
info.size, info.mode = len(metadata), 0o644
expected[metadata_name] = (info, metadata)

if action == 'write':
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as stream:
            temporary = Path(stream.name)
            with gzip.GzipFile(fileobj=stream, mode='wb', filename='', mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode='w', format=tarfile.PAX_FORMAT) as archive:
                    for name, (entry, data) in sorted(expected.items()):
                        entry.name = name
                        # Git may carry a PAX path override for long filenames.
                        # Let tarfile regenerate it from the prefixed name.
                        entry.pax_headers = {}
                        entry.uid = entry.gid = 0
                        entry.uname = entry.gname = ''
                        archive.addfile(entry, io.BytesIO(data) if entry.isfile() else None)
        os.replace(temporary, output)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
elif action == 'verify':
    seen = set()
    with tarfile.open(output, 'r:gz') as archive:
        for entry in archive:
            safe_path(entry.name)
            if entry.name not in expected or entry.name in seen:
                raise SystemExit(f'Unexpected or duplicate delivered source entry: {entry.name}')
            seen.add(entry.name)
            wanted, data = expected[entry.name]
            if entry.type != wanted.type or entry.mode != wanted.mode or entry.linkname != wanted.linkname:
                raise SystemExit(f'Delivered source entry metadata mismatch: {entry.name}')
            if entry.isfile() and archive.extractfile(entry).read() != data:
                raise SystemExit(f'Delivered source bytes mismatch: {entry.name}')
    if seen != set(expected):
        raise SystemExit('Delivered source archive is incomplete')
else:
    raise SystemExit(f'Unsupported source archive action: {action}')
# Refuse a checkout/HEAD change that happened during archive construction.
for repository in repositories:
    repo = root if repository['path'] == '.' else root / repository['path']
    if git(repo, 'rev-parse', 'HEAD').decode().strip() != repository['commit'] or git(repo, 'status', '--porcelain', '--untracked-files=normal').strip():
        raise SystemExit('Source checkout changed while preparing its archive')
PY
}

resolve_apkanalyzer() {
    if [[ -n "${PAPERCUP_APKANALYZER:-}" ]]; then
        printf '%s\n' "$PAPERCUP_APKANALYZER"
        return 0
    fi
    local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"
    local analyzer="$sdk_root/cmdline-tools/latest/bin/apkanalyzer"
    [[ -x "$analyzer" ]] || die "apkanalyzer not found at $analyzer"
    printf '%s\n' "$analyzer"
}

# Exercise the exported source, not the checkout's populated Cargo cache or
# target directory. The locked dependency supplement is prepared separately.
verify_source_build() {
    local mode="$1" commit
    if [[ "$mode" == notices ]]; then
        rm -f "$REPO_ROOT/android/app/build/outputs/papercusp-rust-notices-result.json" \
            "$REPO_ROOT/android/app/build/outputs/papercusp-rust-notices.json"
    else
        rm -f "$REPO_ROOT/android/app/build/outputs/papercusp-source-build-result.json"
    fi
    assert_clean_source
    commit="$(source_commit)"
    source_archive verify "$commit"
    REPO_ROOT="$REPO_ROOT" SOURCE_REL="$SOURCE_REL" python3 - "$mode" "$commit" <<'PY'
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import uuid
import zipfile

mode, commit = sys.argv[1:]
root = Path(os.environ['REPO_ROOT']).resolve()
outputs = root / 'android/app/build/outputs'
source = root / os.environ['SOURCE_REL']
dependencies = outputs / 'papercusp-rust-dependencies.tar.gz'
result_file = outputs / ('papercusp-rust-notices-result.json' if mode == 'notices'
                         else 'papercusp-source-build-result.json')
# A failed attempt must never leave a preceding successful receipt current.
result_file.unlink(missing_ok=True)
started = datetime.now(timezone.utc).isoformat()

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

inputs = {str(path.relative_to(root)): digest(path) for path in (source, dependencies)}
prefix = 'papercusp-mobile-source'
vendor_rel = 'android/app/build/outputs/papercusp-rust-dependencies'
inventory_rel = vendor_rel + '-provenance.json'
supplement_rel = 'android/app/build/outputs/papercusp-rust-license-supplements'
config = {'source': {'crates-io': {'replace-with': 'vendored-sources'},
                     'vendored-sources': {'directory': vendor_rel}}}

def extract(archive_path, destination, supplement=False):
    seen = set()
    with tarfile.open(archive_path, 'r:gz') as archive:
        for entry in archive:
            path = PurePosixPath(entry.name)
            if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != prefix:
                raise SystemExit('Unsafe delivered source path: ' + entry.name)
            if entry.name in seen:
                raise SystemExit('Duplicate delivered source path: ' + entry.name)
            seen.add(entry.name)
            if supplement and not entry.isdir():
                relative = str(path.relative_to(prefix))
                allowed = relative in ('.cargo/config.toml', inventory_rel) or any(
                    relative.startswith(directory + '/') for directory in (vendor_rel, supplement_rel))
                if not allowed or not entry.isfile():
                    raise SystemExit('Unexpected dependency supplement entry: ' + entry.name)
                if (destination / entry.name).exists():
                    raise SystemExit('Dependency supplement overwrites root source: ' + entry.name)
            # Python's maintained filter refuses escaping links and special files.
            archive.extract(entry, destination, filter='data')

with tempfile.TemporaryDirectory(prefix='.source-build-', dir=outputs) as temporary:
    destination = Path(temporary)
    extract(source, destination)
    extracted = destination / prefix
    extract(dependencies, destination, supplement=True)
    if tomllib.loads((extracted / '.cargo/config.toml').read_text()) != config:
        raise SystemExit('Delivered Cargo config differs from the offline vendor recipe')
    inventory = json.loads((extracted / inventory_rel).read_text())
    if inventory.get('cargoLockSha256') != digest(extracted / 'Cargo.lock'):
        raise SystemExit('Dependency supplement is stale for the delivered Cargo.lock')
    lock = tomllib.loads((extracted / 'Cargo.lock').read_text())
    registry = {}
    for package in lock['package']:
        if package.get('source'):
            if package['source'] != 'registry+https://github.com/rust-lang/crates.io-index':
                raise SystemExit('Unsupported locked source requires explicit preparation: ' + package['name'])
            registry[(package['name'], package['version'])] = package['checksum']
    rows = inventory['packages']
    if len(rows) != len(registry) or {(row['name'], row['version']) for row in rows} != set(registry):
        raise SystemExit('Dependency supplement does not cover the locked registry population')
    vendor = extracted / vendor_rel
    if {path.name for path in vendor.iterdir()} != {name + '-' + version for name, version in registry}:
        raise SystemExit('Delivered vendor directory differs from the locked registry population')
    verified_files = 0
    for row in rows:
        name, version = row['name'], row['version']
        package = vendor / (name + '-' + version)
        checksums = json.loads((package / '.cargo-checksum.json').read_text())
        if checksums['package'] != registry[(name, version)] or row['packageChecksum'] != registry[(name, version)]:
            raise SystemExit('Delivered registry checksum differs from Cargo.lock: ' + name)
        actual = {str(path.relative_to(package)) for path in package.rglob('*') if path.is_file()}
        if actual != set(checksums['files']) | {'.cargo-checksum.json'}:
            raise SystemExit('Delivered crate file population differs: ' + name)
        for relative, expected in checksums['files'].items():
            path = PurePosixPath(relative)
            if path.is_absolute() or '..' in path.parts or digest(package / relative) != expected:
                raise SystemExit('Delivered crate file checksum differs: ' + name + '/' + relative)
            verified_files += 1
    if mode == 'notices':
        # Reuse the delivered-source verification above. This population is the
        # complete lockfile, including host/development/platform packages; it is
        # deliberately not a claim about crates linked into an Android binary.
        libraries, licenses, provenance = [], {}, []
        notice_pattern = re.compile(r'(^|[-_.])(licen[cs]es?|copying|notices?|authors?|copyrights?)([-_.]|$)', re.I)
        for row in sorted(rows, key=lambda item: (item['name'], item['version'])):
            name, version = row['name'], row['version']
            package = vendor / (name + '-' + version)
            manifest = tomllib.loads((package / 'Cargo.toml').read_text())['package']
            if (manifest.get('name'), manifest.get('version')) != (name, version):
                raise SystemExit('Notice package identity differs from Cargo.lock: ' + name)
            if (row.get('declaredLicense'), row.get('declaredLicenseFile')) != (
                    manifest.get('license'), manifest.get('license-file')):
                raise SystemExit('Notice license declaration differs from delivered Cargo.toml: ' + name)
            if not manifest.get('license') and not manifest.get('license-file'):
                raise SystemExit('Notice package has no license declaration: ' + name)
            selected = {str(path.relative_to(package)) for path in package.rglob('*')
                        if path.is_file() and notice_pattern.search(path.name)}
            if manifest.get('license-file'):
                declared = PurePosixPath(manifest['license-file'])
                if declared.is_absolute() or '..' in declared.parts:
                    raise SystemExit('Unsafe declared license file: ' + name)
                selected.add(str(declared))
            wanted = {name + '-' + version + '/' + path for path in selected}
            recorded = row.get('noticeFiles', [])
            if len(recorded) != len(wanted) or {entry['path'] for entry in recorded} != wanted:
                raise SystemExit('Notice file inventory omits or substitutes selected files: ' + name)
            references, text_ids = [], []
            for entry in sorted(recorded, key=lambda item: item['path']):
                path = vendor / entry['path']
                if not path.is_file() or digest(path) != entry['sha256']:
                    raise SystemExit('Notice file differs from retained inventory: ' + entry['path'])
                references.append((path, {'path': entry['path'], 'sha256': entry['sha256']}))
            supplement = row.get('licenseSupplement')
            if supplement:
                relative = PurePosixPath(supplement['path'])
                if (relative.is_absolute() or '..' in relative.parts or
                        len(relative.parts) != 2 or relative.parts[0] != Path(supplement_rel).name):
                    raise SystemExit('Unsafe notice supplement path: ' + name)
                path = extracted / Path(supplement_rel).parent / relative
                vcs = json.loads((package / '.cargo_vcs_info.json').read_text())
                revision = supplement.get('sourceRevision')
                if (not revision or not re.fullmatch(r'[0-9a-f]{40}', revision) or
                        vcs.get('git', {}).get('sha1') != revision or
                        not supplement.get('source', '').startswith('https://') or
                        revision not in supplement['source'] or
                        not path.is_file() or digest(path) != supplement['sha256']):
                    raise SystemExit('Notice supplement differs from pinned package source: ' + name)
                references.append((path, dict(supplement)))
            if not references:
                raise SystemExit('Notice package has no retained full text: ' + name)
            for path, reference in references:
                # Decode without newline conversion so UTF-8 source bytes are
                # preserved when the existing notice viewer reads the JSON.
                content = path.read_bytes().decode('utf-8')
                if not content.strip():
                    raise SystemExit('Notice text is empty: ' + name + '/' + path.name)
                identifier = 'rust-' + hashlib.sha256(content.encode()).hexdigest()
                licenses.setdefault(identifier, {'hash': identifier, 'name': path.name, 'content': content})
                text_ids.append(identifier)
                reference['licenseId'] = identifier
            libraries.append({'uniqueId': 'rust:' + name + ':' + version, 'name': name,
                              'artifactVersion': version,
                              'description': 'Locked Rust source package; declared license: ' +
                                  (manifest.get('license') or 'see declared license file') +
                                  '. This inventory includes host, development and platform dependencies.',
                              'licenses': sorted(set(text_ids))})
            provenance.append({'name': name, 'version': version,
                               'declaredLicense': manifest.get('license'),
                               'declaredLicenseFile': manifest.get('license-file'),
                               'packageChecksum': row['packageChecksum'],
                               'texts': [reference for _, reference in references]})
        for relative, expected in inputs.items():
            if digest(root / relative) != expected:
                raise SystemExit('Source input changed during notice generation')
        notice_file = outputs / 'papercusp-rust-notices.json'
        notice_file.write_text(json.dumps({'libraries': libraries, 'licenses': licenses},
                                         ensure_ascii=False, indent=2) + '\n')
        result = {'schemaVersion': 1, 'sourceCommit': commit, 'mode': 'notices',
                  'startedAt': started, 'finishedAt': datetime.now(timezone.utc).isoformat(),
                  'exitCode': 0, 'inputs': inputs, 'cargoLockSha256': inventory['cargoLockSha256'],
                  'verifiedRegistryPackages': len(registry), 'verifiedVendorFiles': verified_files,
                  'packages': provenance, 'uniqueNoticeTexts': len(licenses),
                  'noticeMetadata': {'path': str(notice_file.relative_to(root)), 'sha256': digest(notice_file)},
                  'scope': 'Selected filename/declared-file notices and pinned supplements for every locked registry package. Not Android linkage, complete source-header attribution, app delivery, rights clearance or recipient access.'}
        result_file.write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({key: value for key, value in result.items() if key != 'packages'}))
        raise SystemExit(0)
    environment = dict(os.environ, CARGO_NET_OFFLINE='true', CARGO_TARGET_DIR=str(extracted / 'target'))
    external_inputs = {}
    gradle_inputs = []
    build_id = uuid.uuid4().hex
    if mode == 'android-apk':
        # Config is deliberately supplied, never silently borrowed from a checkout.
        configured = os.environ.get('PAPERCUP_SOURCE_GOOGLE_SERVICES')
        if not configured or not Path(configured).is_file():
            raise SystemExit('PAPERCUP_SOURCE_GOOGLE_SERVICES must name the external Firebase config')
        google_services = Path(configured).resolve()
        document = json.loads(google_services.read_text())
        package_names = {client.get('client_info', {}).get('android_client_info', {}).get('package_name')
                         for client in document.get('client', [])}
        if 'com.papercuspai.operator.mobile' not in package_names:
            raise SystemExit('External Firebase config has no matching Android application ID')
        google_digest = digest(google_services)
        external_inputs['googleServices'] = {'reference': 'PAPERCUP_SOURCE_GOOGLE_SERVICES',
                                            'sha256': google_digest, 'size': google_services.stat().st_size}
        shutil.copyfile(google_services, extracted / 'android/app/google-services.json')
        sdk = Path(os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME') or '')
        if not sdk.is_absolute() or not (sdk / 'platforms/android-36/source.properties').is_file():
            raise SystemExit('Android APK source build requires an explicit API 36 Android SDK')
        ndk = Path(os.environ.get('ANDROID_NDK_HOME') or sdk / 'ndk/27.0.12077973')
        if not (ndk / 'source.properties').is_file():
            raise SystemExit('Android APK source build requires an installed Android NDK')
        java_home = subprocess.check_output(
            ['bash', 'tools/build-scripts/resolve-java-home.sh'], cwd=extracted, text=True).strip()
        environment.update(JAVA_HOME=java_home, ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk),
                           ANDROID_NDK_HOME=str(ndk), CARGO_HOME=str(extracted / '.cargo-home'))
        # Reuse only dependency/distribution caches, not personal properties,
        # init scripts, signing credentials or prior project build outputs.
        cache_home = Path(os.environ.get('GRADLE_USER_HOME') or Path.home() / '.gradle')
        isolated_home = extracted / '.gradle-user-home'
        isolated_home.mkdir()
        for directory in ('caches', 'wrapper'):
            if (cache_home / directory).is_dir():
                (isolated_home / directory).symlink_to((cache_home / directory).resolve(), target_is_directory=True)
        environment['GRADLE_USER_HOME'] = str(isolated_home)
        removed = []
        for key in list(environment):
            if key.startswith(('ORG_GRADLE_PROJECT_', 'PAPERCUP_RELEASE_')) or key in (
                    'PICOVOICE_ACCESS_KEY', 'PAPERCUP_USE_OWW', 'GRADLE_OPTS', 'JAVA_OPTS',
                    'JAVA_TOOL_OPTIONS', 'JDK_JAVA_OPTIONS', '_JAVA_OPTIONS'):
                removed.append(key)
                del environment[key]
        external_inputs['environment'] = {'removedOverrides': sorted(removed), 'personalGradleConfigLoaded': False,
                                          'gradleDependencies': 'existing cache; Gradle offline resolution'}
        external_inputs['sdkPackages'] = [
            {'package': 'platforms/android-36', 'sourcePropertiesSha256': digest(sdk / 'platforms/android-36/source.properties')},
            {'package': 'ndk', 'sourcePropertiesSha256': digest(ndk / 'source.properties')}]
        external_inputs['javaVersion'] = subprocess.check_output(
            [str(Path(java_home) / 'bin/java'), '-version'], stderr=subprocess.STDOUT, text=True).strip()
        external_inputs['rustVersion'] = subprocess.check_output(['rustc', '-vV'], text=True).strip()
        # Hash the actual resolved artifacts instead of calling the cache source.
        (extracted / 'android/source-build-inputs.gradle').write_text('''
import groovy.json.JsonOutput
import java.security.MessageDigest
gradle.projectsEvaluated {
    def app = gradle.rootProject.project(':app')
    app.tasks.register('papercupSourceBuildInputs') {
        doLast {
            def rows = []
            def collect = { config, label ->
                config.resolvedConfiguration.resolvedArtifacts.each { artifact ->
                    def md = MessageDigest.getInstance('SHA-256')
                    artifact.file.withInputStream { stream ->
                        byte[] buffer = new byte[65536]
                        int count
                        while ((count = stream.read(buffer)) > 0) md.update(buffer, 0, count)
                    }
                    rows.add([configuration: label, module: artifact.moduleVersion.id.toString(),
                              file: artifact.file.name, sha256: md.digest().encodeHex().toString(), size: artifact.file.length()])
                }
            }
            ['debugRuntimeClasspath', 'debugCompileClasspath', 'coreLibraryDesugaring'].each { name ->
                collect(app.configurations.getByName(name), name)
            }
            gradle.rootProject.allprojects.each { project ->
                def config = project.buildscript.configurations.findByName('classpath')
                if (config) collect(config, project.path + ':buildscript')
            }
            app.buildDir.mkdirs()
            new File(app.buildDir, 'source-build-inputs.json').text = JsonOutput.toJson(rows.sort { a,b ->
                (a.configuration + a.module + a.file) <=> (b.configuration + b.module + b.file)
            })
        }
    }
}
''')
    metadata = json.loads(subprocess.check_output(
        ['cargo', 'metadata', '--frozen', '--format-version', '1'], cwd=extracted, env=environment))
    resolved = [package for package in metadata['packages'] if package.get('source')]
    if {(package['name'], package['version']) for package in resolved} != set(registry):
        raise SystemExit('Extracted Cargo graph differs from the locked registry population')
    if any(not Path(package['manifest_path']).resolve().is_relative_to(vendor) for package in resolved):
        raise SystemExit('Cargo resolved a registry dependency outside the delivered source')
    if mode == 'host':
        version = subprocess.check_output(['rustc', '-vV'], text=True)
        target = next(line.removeprefix('host: ') for line in version.splitlines() if line.startswith('host: '))
        commands = [['cargo', 'build', '--frozen', '--release', '--lib', '-p', 'papercup-bindings', '--target', target]]
        targets = [target]
    else:
        targets = ['aarch64-linux-android', 'armv7-linux-androideabi', 'i686-linux-android', 'x86_64-linux-android']
        commands = [['cargo', 'ndk', '-t', 'arm64-v8a', '-t', 'armeabi-v7a', '-t', 'x86', '-t', 'x86_64',
                     'build', '--frozen', '--release', '--lib', '-p', 'papercup-bindings']]
        if mode == 'android-apk':
            commands[0][10:10] = ['-o', 'android/app/src/main/jniLibs']
            commands.extend([
                ['cargo', 'run', '--frozen', '--quiet', '--bin', 'uniffi-bindgen', '--', 'generate',
                 'crates/papercup-bindings/src/papercup.udl', '--language', 'kotlin', '--out-dir', 'android/app/src/main/kotlin'],
                ['bash', 'tools/build-scripts/verify-android-uniffi-abi.sh',
                 'android/app/src/main/kotlin/uniffi/papercup/papercup.kt',
                 *['android/app/src/main/jniLibs/' + abi + '/libpapercup.so'
                   for abi in ('arm64-v8a', 'armeabi-v7a', 'x86', 'x86_64')]],
                ['android/gradlew', '-p', 'android', '--offline', '--no-daemon', '--console=plain',
                 '--init-script', 'source-build-inputs.gradle', '-x', ':app:generateUniFfiKotlin',
                 ':app:assembleDebug', ':app:papercupSourceBuildInputs']])
            # Resolve the real init script/plugins/dependencies before spending
            # minutes compiling four Rust ABIs; reuse exactly the final route.
            commands.insert(0, [argument for argument in commands[-1] if argument != ':app:assembleDebug'])
    log = outputs / ('papercusp-source-build-' + build_id + '.log')
    exit_code = 0
    with log.open('w') as stream:
        for command in commands:
            stream.write('STEP: ' + json.dumps(command) + '\n')
            stream.flush()
            exit_code = subprocess.run(command, cwd=extracted, env=environment, stdout=stream, stderr=subprocess.STDOUT).returncode
            if exit_code:
                break
            if mode == 'android-apk' and command == commands[0]:
                preflight_inputs = json.loads((extracted / 'android/app/build/source-build-inputs.json').read_text())
                if not preflight_inputs:
                    raise SystemExit('Gradle preflight produced no resolved artifacts')
    artifacts = []
    if not exit_code:
        for target in targets:
            filename = 'papercup.dll' if 'windows' in target else 'libpapercup.dylib' if 'darwin' in target else 'libpapercup.so'
            path = extracted / 'target' / target / 'release' / filename
            if not path.is_file() or not path.stat().st_size:
                raise SystemExit('Compilation produced no native library for ' + target)
            artifacts.append({'target': target, 'sha256': digest(path), 'size': path.stat().st_size})
        if mode == 'android-apk':
            apk = extracted / 'android/app/build/outputs/apk/debug/app-debug.apk'
            if not apk.is_file() or not apk.stat().st_size:
                raise SystemExit('Gradle produced no exported-source debug APK')
            packaged_native = []
            with zipfile.ZipFile(apk) as archive:
                names = archive.namelist()
                if len(names) != len(set(names)) or 'classes.dex' not in names or 'AndroidManifest.xml' not in names:
                    raise SystemExit('Gradle output is not a complete debug APK')
                if {name.split('/')[1] for name in names if name.startswith('lib/') and name.endswith('.so')} != {
                        'arm64-v8a', 'armeabi-v7a', 'x86', 'x86_64'}:
                    raise SystemExit('Exported-source APK has an unexpected native ABI population')
                for abi in ('arm64-v8a', 'armeabi-v7a', 'x86', 'x86_64'):
                    name = 'lib/' + abi + '/libpapercup.so'
                    native = extracted / 'android/app/build/intermediates/stripped_native_libs/debug/stripDebugDebugSymbols/out' / name
                    expected = digest(native)
                    if hashlib.sha256(archive.read(name)).hexdigest() != expected:
                        raise SystemExit('APK native library differs from this Gradle build: ' + abi)
                    packaged_native.append({'abi': abi, 'sha256': expected})
            gradle_inputs = json.loads((extracted / 'android/app/build/source-build-inputs.json').read_text())
            if not gradle_inputs or any(not row.get('module') or len(row.get('sha256', '')) != 64 or row.get('size', 0) <= 0
                                       for row in gradle_inputs):
                raise SystemExit('Gradle resolved-artifact provenance is missing or invalid')
            binding = extracted / 'android/app/src/main/kotlin/uniffi/papercup/papercup.kt'
            external_inputs['generatedKotlinSha256'] = digest(binding)
            external_inputs['packagedRustLibraries'] = packaged_native
            retained = outputs / ('papercusp-exported-app-debug-' + build_id + '.apk')
            shutil.copyfile(apk, retained)
            artifacts.append({'target': 'android-debug-apk', 'path': str(retained.relative_to(root)),
                              'sha256': digest(retained), 'size': retained.stat().st_size})
    if mode == 'android-apk' and (digest(google_services) != google_digest or
                                 digest(extracted / 'android/app/google-services.json') != google_digest):
        raise SystemExit('External Firebase config changed during source compilation')
    for relative, expected in inputs.items():
        if digest(root / relative) != expected:
            raise SystemExit('Delivered source input changed during compilation')
    if subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip() != commit or subprocess.check_output(
            ['git', '-C', str(root), 'status', '--porcelain', '--untracked-files=normal']).strip():
        raise SystemExit('Source checkout changed during compilation')
    result = {'schemaVersion': 1, 'sourceCommit': commit, 'mode': mode,
              'startedAt': started, 'finishedAt': datetime.now(timezone.utc).isoformat(),
              'inputSha256': inputs, 'cargoLockSha256': inventory['cargoLockSha256'],
              'verifiedRegistryPackages': len(registry), 'verifiedVendorFiles': verified_files,
              'commands': commands, 'exitCode': exit_code, 'compiledArtifacts': artifacts,
              'log': {'path': str(log.relative_to(root)), 'sha256': digest(log)},
              'externalInputs': external_inputs, 'resolvedGradleArtifacts': gradle_inputs,
              'scope': ('Exported-source Android debug APK compilation only; signed candidate, license clearance and recipient retrieval remain separate.'
                        if mode == 'android-apk' else 'Offline exported-source compilation only; native app, signed candidate, license clearance and recipient retrieval remain separate.')}
    result_file.write_text(json.dumps(result, indent=2) + '\n')
    if exit_code:
        raise SystemExit('Exported-source compilation failed; receipt and unique log retained')
    print(json.dumps(result))
PY
}

assert_canonical_artifact() {
    local supplied="$1" expected_rel="$2" supplied_real expected_real
    [[ -f "$supplied" ]] || die "required Android release artifact missing: $supplied"
    supplied_real="$(realpath "$supplied")"
    expected_real="$(realpath "$REPO_ROOT/$expected_rel")"
    [[ "$supplied_real" == "$expected_real" ]] \
        || die "non-canonical Android artifact path: got $supplied_real, expected $expected_real"
}

write_manifest() {
    local version="$1" apk="${2:-$REPO_ROOT/$APK_REL}" aab="${3:-$REPO_ROOT/$AAB_REL}"
    local commit analyzer apk_version apk_version_code expected_version_code built_at tmp
    [[ -n "$version" ]] || die "release version is required"
    expected_version_code="$(version_code_for "$version")"
    assert_canonical_artifact "$apk" "$APK_REL"
    assert_canonical_artifact "$aab" "$AAB_REL"
    assert_clean_source
    commit="$(source_commit)"
    analyzer="$(resolve_apkanalyzer)"
    apk_version="$("$analyzer" manifest version-name "$apk")"
    [[ "$apk_version" == "$version" ]] \
        || die "APK versionName is $apk_version, but requested release version is $version"
    apk_version_code="$("$analyzer" manifest version-code "$apk")"
    [[ "$apk_version_code" =~ ^[1-9][0-9]*$ ]] \
        || die "APK versionCode must be a positive integer (got $apk_version_code)"
    [[ "$apk_version_code" == "$expected_version_code" ]] \
        || die "APK versionCode is $apk_version_code, but requested release version derives versionCode $expected_version_code"
    source_archive write "$commit"
    built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$MANIFEST")"
    tmp="${MANIFEST}.tmp.$$"
    RELEASE_VERSION="$version" RELEASE_VERSION_CODE="$expected_version_code" SOURCE_COMMIT="$commit" BUILT_AT="$built_at" \
        APK_SIZE="$(stat -c%s "$apk")" APK_SHA256="$(sha256_file "$apk")" \
        AAB_SIZE="$(stat -c%s "$aab")" AAB_SHA256="$(sha256_file "$aab")" \
        SOURCE_SIZE="$(stat -c%s "$REPO_ROOT/$SOURCE_REL")" SOURCE_SHA256="$(sha256_file "$REPO_ROOT/$SOURCE_REL")" \
        node - "$tmp" <<'NODE'
const fs = require('node:fs');
const out = process.argv[2];
const artifact = (kind, relativePath, size, sha256) => ({
  kind,
  path: relativePath,
  size: Number(size),
  sha256,
});
const manifest = {
  schemaVersion: 1,
  releaseVersion: process.env.RELEASE_VERSION,
  versionCode: Number(process.env.RELEASE_VERSION_CODE),
  sourceCommit: process.env.SOURCE_COMMIT,
  sourceDirty: false,
  builtAt: process.env.BUILT_AT,
  artifacts: {
    apk: artifact('apk', 'android/app/build/outputs/apk/release/app-release.apk', process.env.APK_SIZE, process.env.APK_SHA256),
    aab: artifact('aab', 'android/app/build/outputs/bundle/release/app-release.aab', process.env.AAB_SIZE, process.env.AAB_SHA256),
    source: artifact('source', 'android/app/build/outputs/papercusp-mobile-source.tar.gz', process.env.SOURCE_SIZE, process.env.SOURCE_SHA256),
  },
};
fs.writeFileSync(out, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
NODE
    mv -f "$tmp" "$MANIFEST"
    verify_manifest "$version"
    render_record
    echo "==> Android release provenance: $MANIFEST"
    echo "==> Android release candidate record: $RECORD"
}

# Render the human-readable candidate record from the manifest, into the
# gitignored build-output tree. The record is DERIVED, never hand-maintained,
# and never tracked: refreshing it cannot dirty the source tree or move HEAD,
# so the evidence surface can no longer invalidate the provenance it describes.
render_record() {
    local tmp
    [[ -f "$MANIFEST" ]] \
        || die "cannot render release record before provenance manifest exists: $MANIFEST"
    mkdir -p "$(dirname "$RECORD")"
    tmp="${RECORD}.tmp.$$"
    MANIFEST="$MANIFEST" RECORD_REL="$RECORD_REL" MANIFEST_REL="$MANIFEST_REL" \
        node - "$tmp" <<'NODE'
const fs = require('node:fs');
const out = process.argv[2];
let manifest;
try { manifest = JSON.parse(fs.readFileSync(process.env.MANIFEST, 'utf8')); }
catch (error) { throw new Error(`cannot parse provenance manifest: ${error.message}`); }
const bytes = (value) => Number(value).toLocaleString('en-US');
const lines = [
  '# Android release candidate (generated — do not edit, do not commit)',
  '',
  `Generated from \`${process.env.MANIFEST_REL}\` by`,
  '`tools/build-scripts/android-release-provenance.sh`. This file is build',
  'output and is deliberately untracked: refreshing it can never dirty the',
  'source tree or move HEAD, so it cannot invalidate the provenance it',
  'describes. The JSON manifest remains authoritative for upload.',
  '',
  '| Field | Value |',
  '|---|---|',
  `| Release version | \`${manifest.releaseVersion}\` (\`versionCode\` ${manifest.versionCode}) |`,
  `| Source commit | \`${manifest.sourceCommit}\` |`,
  `| Source dirty | ${manifest.sourceDirty} |`,
  `| Built at | ${manifest.builtAt} |`,
];
for (const kind of ['apk', 'aab', 'source']) {
  const artifact = manifest.artifacts?.[kind];
  if (!artifact) throw new Error(`manifest is missing the ${kind} artifact`);
  const label = kind.toUpperCase();
  lines.push(`| ${label} | \`${artifact.path}\` |`);
  lines.push(`| ${label} size | ${bytes(artifact.size)} bytes |`);
  lines.push(`| ${label} SHA-256 | \`${artifact.sha256}\` |`);
}
lines.push(
  '',
  'Re-verify these exact artifacts against the manifest with:',
  '',
  '```sh',
  `tools/build-scripts/android-release-provenance.sh verify ${manifest.releaseVersion}`,
  '```',
  '',
  'The source archive includes committed root files and recursively pinned submodules.',
  'Third-party corresponding source, license clearance and recipient retrieval remain separate checks.',
  '',
);
fs.writeFileSync(out, lines.join('\n'), { mode: 0o600 });
NODE
    mv -f "$tmp" "$RECORD"
}

verify_manifest() {
    local version="$1" commit dirty expected_version_code
    [[ -f "$MANIFEST" ]] || die "Android release provenance missing: $MANIFEST"
    expected_version_code="$(version_code_for "$version")"
    assert_clean_source
    commit="$(source_commit)"
    dirty="false"
    EXPECTED_VERSION="$version" EXPECTED_VERSION_CODE="$expected_version_code" EXPECTED_COMMIT="$commit" EXPECTED_DIRTY="$dirty" \
        REPO_ROOT="$REPO_ROOT" MANIFEST="$MANIFEST" node <<'NODE'
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const fail = (message) => { throw new Error(message); };
const hashFile = (file) => {
  const hash = crypto.createHash('sha256');
  const fd = fs.openSync(file, 'r');
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  try {
    for (;;) {
      const count = fs.readSync(fd, buffer, 0, buffer.length, null);
      if (count === 0) break;
      hash.update(buffer.subarray(0, count));
    }
  } finally {
    fs.closeSync(fd);
  }
  return hash.digest('hex');
};

let manifest;
try { manifest = JSON.parse(fs.readFileSync(process.env.MANIFEST, 'utf8')); }
catch (error) { fail(`cannot parse provenance manifest: ${error.message}`); }
if (manifest.schemaVersion !== 1) fail(`unsupported schemaVersion ${manifest.schemaVersion}`);
if (manifest.releaseVersion !== process.env.EXPECTED_VERSION) fail('releaseVersion mismatch');
if (manifest.versionCode !== Number(process.env.EXPECTED_VERSION_CODE) || manifest.versionCode <= 0) fail('versionCode mismatch');
if (manifest.sourceCommit !== process.env.EXPECTED_COMMIT) fail('sourceCommit mismatch');
if (manifest.sourceDirty !== false) fail('sourceDirty must be false');
for (const [kind, rel] of [
  ['apk', 'android/app/build/outputs/apk/release/app-release.apk'],
  ['aab', 'android/app/build/outputs/bundle/release/app-release.aab'],
  ['source', 'android/app/build/outputs/papercusp-mobile-source.tar.gz'],
]) {
  const entry = manifest.artifacts?.[kind];
  if (!entry || entry.kind !== kind || entry.path !== rel) fail(`${kind} path/kind mismatch`);
  const file = path.join(process.env.REPO_ROOT, rel);
  const stat = fs.statSync(file);
  if (!stat.isFile() || stat.size !== entry.size) fail(`${kind} size mismatch`);
  if (!/^[0-9a-f]{64}$/.test(entry.sha256) || hashFile(file) !== entry.sha256) fail(`${kind} sha256 mismatch`);
}
NODE
    source_archive verify "$commit"
}

case "${1:-}" in
    write)
        [[ $# -ge 2 && $# -le 4 ]] || die "usage: $0 write <version> [apk] [aab]"
        write_manifest "$2" "${3:-$REPO_ROOT/$APK_REL}" "${4:-$REPO_ROOT/$AAB_REL}"
        ;;
    verify)
        [[ $# -eq 2 ]] || die "usage: $0 verify <version>"
        verify_manifest "$2"
        echo "==> Verified Android release provenance for $2"
        ;;
    render)
        [[ $# -eq 1 ]] || die "usage: $0 render"
        render_record
        echo "==> Android release candidate record: $RECORD"
        ;;
    path)
        [[ $# -eq 1 ]] || die "usage: $0 path"
        printf '%s\n' "$MANIFEST"
        ;;
    record)
        [[ $# -eq 1 ]] || die "usage: $0 record"
        printf '%s\n' "$RECORD"
        ;;
    source-archive)
        [[ $# -eq 1 ]] || die "usage: $0 source-archive"
        assert_clean_source
        commit="$(source_commit)"
        source_archive write "$commit"
        source_archive verify "$commit"
        printf '%s\n' "$REPO_ROOT/$SOURCE_REL"
        ;;
    source-verify-build)
        [[ $# -le 2 ]] || die "usage: $0 source-verify-build [host|android|android-apk]"
        mode="${2:-host}"
        [[ "$mode" == host || "$mode" == android || "$mode" == android-apk ]] || die "source build mode must be host, android or android-apk"
        verify_source_build "$mode"
        ;;
    source-notices)
        [[ $# -eq 1 ]] || die "usage: $0 source-notices"
        verify_source_build notices
        ;;
    *)
        die "usage: $0 {write <version> [apk] [aab]|verify <version>|render|path|record|source-archive|source-notices|source-verify-build [host|android|android-apk]}"
        ;;
esac

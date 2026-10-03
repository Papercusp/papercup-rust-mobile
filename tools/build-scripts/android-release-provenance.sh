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

# Package pinned upstream inputs without treating a source snapshot as proof of
# the invocation that produced Maven's prebuilt dispatcher. Reuse the existing
# source archive command and selected-dependency provenance directory.
jna_tree_validation_code() {
    cat <<'PY'
def pinned_jna_tree(tree, pin):
    if tree.get('truncated') is not False:
        raise SystemExit('JNA source tree must be complete')
    rows = {}
    directories = {row['path'] for row in tree['tree'] if row['type'] == 'tree'}
    for row in tree['tree']:
        name = row['path']
        path = PurePosixPath(name)
        if (not name or path.is_absolute() or '..' in path.parts or str(path) != name or
                '\\' in name or '\0' in name or name in rows):
            raise SystemExit('Unsafe or duplicate JNA tree path: ' + name)
        if (row['type'], row['mode']) not in (('tree', '040000'), ('blob', '100644'), ('blob', '100755')):
            raise SystemExit('Unsupported JNA tree entry: ' + name)
        if len(row['sha']) != 40 or any(c not in '0123456789abcdef' for c in row['sha']):
            raise SystemExit('Invalid JNA Git object identity: ' + name)
        if str(path.parent) != '.' and str(path.parent) not in directories:
            raise SystemExit('JNA tree omits a parent: ' + name)
        rows[name] = row
    for directory in [''] + sorted(directories):
        children = [row for name, row in rows.items() if str(PurePosixPath(name).parent) == (directory or '.')]
        children.sort(key=lambda row: (PurePosixPath(row['path']).name + ('/' if row['type'] == 'tree' else '')).encode())
        data = b''.join(row['mode'].lstrip('0').encode() + b' ' + PurePosixPath(row['path']).name.encode() +
                        b'\0' + bytes.fromhex(row['sha']) for row in children)
        wanted = rows[directory]['sha'] if directory else pin['sourceTreeSha1']
        actual = hashlib.sha1(b'tree ' + str(len(data)).encode() + b'\0' + data).hexdigest()
        if actual != wanted:
            raise SystemExit('JNA tree identity differs from pinned source: ' + (directory or '.'))
    root_files = {'LICENSE', 'AL2.0', 'LGPL2.1', 'OTHERS', 'README.md', 'build.xml', 'common.xml', 'build-ant-tools.xml'}
    prefixes = ('native/', 'src/', 'ant-tools-src/')
    selected = {name: row for name, row in rows.items() if row['type'] == 'blob' and
                (name in root_files or name.startswith(prefixes))}
    if not root_files <= selected.keys() or any(not any(name.startswith(prefix) for name in selected) for prefix in prefixes):
        raise SystemExit('JNA source tree omits required build/source inputs')
    return rows, selected

def jna_configured_native_files(build, files):
    import fnmatch
    # DirectoryScanner.DEFAULTEXCLUDES from the pinned Ant 1.10.15 runtime.
    # Ant applies these as well as the explicit upstream zipfileset exclusions.
    defaults = ('*~', '#*#', '.#*', '%*%', '._*', 'CVS', '.cvsignore', 'SCCS', 'vssver.scc',
                '.svn', '.git', '.gitattributes', '.gitignore', '.gitmodules', '.hg', '.hgignore',
                '.hgsub', '.hgsubstate', '.hgtags', '.bzr', '.bzrignore', '.DS_Store')
    explicit = [row.attrib['name'] for row in build.findall('./target[@name="native-build-package"]//zipfileset[@dir="native"]/exclude')]
    included, excluded = {}, []
    for name, data in sorted(files.items()):
        if not name.startswith('native/'):
            continue
        relative = name.removeprefix('native/')
        if (any(fnmatch.fnmatchcase(relative, pattern) for pattern in explicit) or
                any(fnmatch.fnmatchcase(part, pattern) for part in PurePosixPath(relative).parts for pattern in defaults)):
            excluded.append(name)
        else:
            included[name] = data
    return included, excluded
PY
}

source_archive_jna() {
    local source_dir="$1" receipt="$REPO_ROOT/android/app/build/outputs/papercusp-jna-source-result.json"
    rm -f "$receipt"
    assert_clean_source
    REPO_ROOT="$REPO_ROOT" JNA_TREE_VALIDATION_CODE="$(jna_tree_validation_code)" python3 - "$source_dir" "$(source_commit)" <<'PY'
from datetime import datetime, timezone
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

root = Path(os.environ['REPO_ROOT']).resolve()
source, commit = Path(sys.argv[1]), sys.argv[2]
outputs = root / 'android/app/build/outputs'
tree_file = outputs / 'papercusp-android-dependency-sources/jna-NATIVE-TREE.json'
pins_file = root / 'android/config/SOURCES.json'
started = datetime.now(timezone.utc).isoformat()
digest = lambda data: hashlib.sha256(data).hexdigest()
git_hash = lambda kind, data: hashlib.sha1(kind + b' ' + str(len(data)).encode() + b'\0' + data).hexdigest()
pins_bytes, tree_bytes = pins_file.read_bytes(), tree_file.read_bytes()
pins = [row for row in json.loads(pins_bytes)['licenses'] if row['key'] == 'jna-libffi']
if len(pins) != 1:
    raise SystemExit('JNA source pin must be unique')
pin = pins[0]
tree = json.loads(tree_bytes)
exec(os.environ['JNA_TREE_VALIDATION_CODE'])
rows, selected = pinned_jna_tree(tree, pin)
if not source.is_dir() or source.is_symlink():
    raise SystemExit('JNA source input must be a regular directory')
actual = set()
for directory, directories, files in os.walk(source, followlinks=False):
    for name in directories + files:
        path = Path(directory) / name
        if path.is_symlink() or (name in files and not path.is_file()):
            raise SystemExit('JNA source input contains a symlink or special file')
    actual.update(str((Path(directory) / name).relative_to(source)) for name in files)
if actual != selected.keys():
    raise SystemExit('JNA source file population differs from pinned selected inputs')
verified, entries = [], {}
for name, row in sorted(selected.items()):
    data = (source / name).read_bytes()
    if len(data) != row['size'] or git_hash(b'blob', data) != row['sha']:
        raise SystemExit('JNA source bytes differ from pinned Git blob: ' + name)
    entries[name] = (data, 0o755 if row['mode'] == '100755' else 0o644)
    verified.append({'path': name, 'gitBlob': row['sha'], 'sha256': digest(data), 'size': len(data)})
if digest(entries['native/libffi/LICENSE'][0]) != pin['sourceSha256']:
    raise SystemExit('JNA libffi license differs from existing notice pin')
scope = ('Selected pinned JNA native, Java, Ant-tool sources and root build/license files. '
         'Includes foreign architectures and tests; excludes prebuilt libraries/tool JARs. '
         'Not an exact Android compilation census, original prebuilt invocation, license election, '
         'signed candidate, complete standalone toolchain or recipient retrieval proof.')
metadata = {'schemaVersion': 1, 'sourceRevision': pin['sourceRevision'], 'sourceTreeSha1': pin['sourceTreeSha1'],
            'files': verified, 'scope': scope}
entries['SOURCE-PROVENANCE.json'] = ((json.dumps(metadata, sort_keys=True, indent=2) + '\n').encode(), 0o644)
archive_path = outputs / 'papercusp-jna-source.tar.gz'
with tempfile.NamedTemporaryFile(dir=outputs, delete=False) as stream:
    temporary = Path(stream.name)
    try:
        with gzip.GzipFile(fileobj=stream, mode='wb', filename='', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.PAX_FORMAT) as archive:
                for name, (data, mode) in sorted(entries.items()):
                    info = tarfile.TarInfo('papercusp-jna-source/' + name)
                    info.size, info.mode = len(data), mode
                    archive.addfile(info, io.BytesIO(data))
        stream.flush()
        with tarfile.open(temporary, 'r:gz') as archive:
            members = archive.getmembers()
            if len(members) != len(entries) or {m.name for m in members} != {'papercusp-jna-source/' + name for name in entries}:
                raise SystemExit('Generated JNA source archive population differs')
            for member in members:
                data, mode = entries[member.name.removeprefix('papercusp-jna-source/')]
                if not member.isfile() or member.mode != mode or archive.extractfile(member).read() != data:
                    raise SystemExit('Generated JNA source archive bytes differ')
        if pins_file.read_bytes() != pins_bytes or tree_file.read_bytes() != tree_bytes or any(
                digest((source / row['path']).read_bytes()) != row['sha256'] for row in verified):
            raise SystemExit('JNA source input changed during packaging')
        if subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD']).decode().strip() != commit or subprocess.check_output(
                ['git', '-C', str(root), 'status', '--porcelain', '--untracked-files=normal']).strip():
            raise SystemExit('Mobile source changed during JNA packaging')
        os.replace(temporary, archive_path)
    finally:
        temporary.unlink(missing_ok=True)
result = dict(metadata, mobileSourceCommit=commit, startedAt=started,
              finishedAt=datetime.now(timezone.utc).isoformat(), exitCode=0,
              producerSha256=digest((root / 'tools/build-scripts/android-release-provenance.sh').read_bytes())
                  if (root / 'tools/build-scripts/android-release-provenance.sh').is_file() else None,
              inputTreeSha256=digest(tree_bytes), inputPinsSha256=digest(pins_bytes),
              archive={'path': str(archive_path.relative_to(root)), 'sha256': digest(archive_path.read_bytes()),
                       'size': archive_path.stat().st_size}, verifiedFiles=len(verified))
(outputs / 'papercusp-jna-source-result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({key: value for key, value in result.items() if key != 'files'}))
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

# Consume an already retained selected JNA package. This is an offline input
# check, deliberately not an Ant/native build or a recipient-delivery claim.
verify_jna_inputs() {
    local package_dir="$1" mode="${2:-jna-inputs}" abi="${3:-all}" receipt
    if [[ "$mode" == jna-configure ]]; then
        receipt="$REPO_ROOT/android/app/build/outputs/papercusp-jna-configure-result.json"
    elif [[ "$mode" == jna-native ]]; then
        receipt="$REPO_ROOT/android/app/build/outputs/papercusp-jna-native-result.json"
    else
        receipt="$REPO_ROOT/android/app/build/outputs/papercusp-jna-build-inputs-result.json"
    fi
    rm -f "$receipt"
    assert_clean_source
    REPO_ROOT="$REPO_ROOT" JNA_TREE_VALIDATION_CODE="$(jna_tree_validation_code)" python3 - "$package_dir" "$(source_commit)" "$mode" "$abi" <<'PY'
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import fnmatch
import shutil
import shlex
import struct
import subprocess
import sys
import tarfile
import tempfile
import xml.etree.ElementTree as ET
import zipfile

root, package = Path(os.environ['REPO_ROOT']).resolve(), Path(sys.argv[1])
commit = sys.argv[2]
mode = sys.argv[3]
started = datetime.now(timezone.utc).isoformat()
digest = lambda data: hashlib.sha256(data).hexdigest()
blob = lambda data: hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
snapshots = {}

def read(path, remember=True):
    if path.is_symlink() or not path.is_file():
        raise SystemExit('JNA input must be a regular file: ' + str(path))
    data = path.read_bytes()
    if remember:
        snapshots[path] = data
    return data

def safe(name):
    path = PurePosixPath(name)
    if not name or path.is_absolute() or '..' in path.parts or str(path) != name or '\\' in name or '\0' in name:
        raise SystemExit('Unsafe JNA input path: ' + name)
    return name

def jna_native_preflight(environment, ndk):
    # autogen.sh execs autoreconf; regenerated libffi documentation needs texinfo.
    # Check the entire host-tool population before invoking any native make.
    names = ('make', 'autoreconf', 'autoconf', 'automake', 'aclocal', 'autoheader',
             'libtoolize', 'm4', 'perl', 'makeinfo', 'sed', 'awk', 'grep', 'patch')
    paths = {}
    for name in names:
        path = shutil.which(name, path=environment.get('PATH'))
        if not path:
            raise SystemExit('JNA native prerequisite missing: ' + name)
        paths[name] = Path(path).resolve()
    tools = []
    for name, path in paths.items():
        arguments = ['-W', 'version'] if name == 'awk' else ['--version']
        completed = subprocess.run([str(path)] + arguments, env=environment,
                                   capture_output=True, text=True)
        if completed.returncode:
            raise SystemExit('JNA native prerequisite version failed: ' + name)
        tools.append(dict(name=name, path=str(path), sha256=digest(path.read_bytes()),
                          version=(completed.stdout + completed.stderr).strip()))
    properties = ndk / 'source.properties'
    if not properties.is_file() or not re.search(r'^Pkg.Revision\s*=\s*27\.0\.12077973\s*$', properties.read_text(), re.M):
        raise SystemExit('JNA native requires NDK 27.0.12077973')
    llvm = ndk / 'toolchains/llvm/prebuilt/linux-x86_64'
    sysroot = llvm / 'sysroot'
    if not (sysroot / 'usr/include/jni.h').is_file():
        raise SystemExit('JNA native NDK sysroot/JNI headers missing')
    return tools, llvm, sysroot

def jna_native_command(make, llvm, work, arch, compiler, version, checksum):
    # Command-line variables are exported to configure AND recursive make.
    # FFI_ENV clears link/output flags for configure; MAKEOVERRIDES prevents
    # the dispatcher's target-specific overrides entering libffi's make.
    quote = lambda path: shlex.quote(str(path))
    cc = quote(compiler)
    includes = '-I' + quote(work / 'headers') + ' -I' + quote(work / 'build/libffi/include')
    return [str(make), '-j2', 'OS=android', 'ARCH=' + arch, 'BUILD=../build',
            'JAVAH=' + str(work / 'headers'), 'JNA_JNI_VERSION=' + version,
            'CHECKSUM=' + checksum, 'DYNAMIC_LIBFFI=false', 'DEBUG=false', 'CFLAGS_EXTRA=',
            'CC=' + cc, 'CPP=' + cc + ' -E', 'LD=' + cc,
            'AR=' + quote(llvm / 'bin/llvm-ar'), 'RANLIB=' + quote(llvm / 'bin/llvm-ranlib'),
            'STRIP=' + quote(llvm / 'bin/llvm-strip') + ' -x', 'CINCLUDES=' + includes,
            'COPT=-O2 -fno-omit-frame-pointer -fno-strict-aliasing -Wno-implicit-function-declaration -fpic -ffunction-sections -funwind-tables -fno-short-enums',
            'LIBS=-lc -ldl -lm',
            'LDFLAGS=-o $@ -shared -Wl,-Bsymbolic -Wl,--build-id=sha1 -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384',
            'MAKEOVERRIDES=',
            'FFI_ENV=LDFLAGS= CC="$(CC)" CPP="$(CPP)" CFLAGS="$(COPT) $(CDEBUG) $(CINCLUDES)" CPPFLAGS="$(CDEFINES) $(CINCLUDES)" LIBS="$(LIBS)" AR="$(AR)" RANLIB="$(RANLIB)"',
            '../build/libjnidispatch.so']

def jna_native_stub(data, version):
    import io
    with zipfile.ZipFile(io.BytesIO(data)) as jar:
        if sorted(jar.namelist()) != ['META-INF/', 'META-INF/MANIFEST.MF']:
            raise SystemExit('JNA configured stub JAR population differs')
        manifest = jar.read('META-INF/MANIFEST.MF').decode().replace('\r\n', '\n')
        if '\nSpecification-Version: ' + version + '\n' not in manifest:
            raise SystemExit('JNA configured stub JAR version differs')

def jna_native_headers(entries, headers, version, checksum):
    expected = {'headers/' + header['path'] for header in headers}
    expected |= {'headers/jni.properties', 'headers/jni.checksum', 'headers/jni.checksum.error'}
    if {name for name in entries if name.startswith('headers/')} != expected:
        raise SystemExit('JNA configured generated-header population differs')
    if any(digest(entries['headers/' + header['path']]) != header['sha256'] for header in headers):
        raise SystemExit('JNA configured header fingerprint differs')
    generated = dict(line.split('=', 1) for line in entries['headers/jni.properties'].decode().splitlines()
                     if line and not line.startswith('#') and '=' in line)
    if (generated.get('version') != version or generated.get('checksum') != checksum or
            hashlib.md5(entries['headers/jni.checksum']).hexdigest() != checksum or entries['headers/jni.checksum.error']):
        raise SystemExit('JNA configured JNI identity/checksum differs')

def jna_native_elf(path, elf_class, machine, readelf, version, checksum):
    data = path.read_bytes()
    if len(data) < 64 or data[:4] != b'\x7fELF' or data[4:6] != bytes((elf_class, 1)):
        raise SystemExit('JNA native output is not the required little-endian ELF class')
    if struct.unpack_from('<HH', data, 16) != (3, machine):
        raise SystemExit('JNA native ELF type/machine differs')
    if elf_class == 2:
        offset = struct.unpack_from('<Q', data, 32)[0]
        size, count = struct.unpack_from('<HH', data, 54)
        layout = '<IIQQQQQQ'
    else:
        offset = struct.unpack_from('<I', data, 28)[0]
        size, count = struct.unpack_from('<HH', data, 42)
        layout = '<IIIIIIII'
    if size != struct.calcsize(layout) or not count or offset + size * count > len(data):
        raise SystemExit('JNA native ELF program headers invalid')
    loads = []
    for index in range(count):
        row = struct.unpack_from(layout, data, offset + index * size)
        if row[0] != 1:
            continue
        file_offset, address, alignment = (row[2], row[3], row[7]) if elf_class == 2 else (row[1], row[2], row[7])
        if alignment < 16384 or alignment & (alignment - 1) or (address - file_offset) % 16384:
            raise SystemExit('JNA native ELF LOAD is not 16 KB aligned')
        loads.append(dict(offset=file_offset, address=address, alignment=alignment))
    if not loads:
        raise SystemExit('JNA native ELF has no LOAD segments')
    completed = subprocess.run([str(readelf), '--dyn-syms', '--wide', str(path)],
                               capture_output=True, text=True, check=True)
    symbols = {row.split()[-1].split('@')[0] for row in completed.stdout.splitlines()
               if len(row.split()) >= 8 and row.split()[6] != 'UND'}
    required = {'JNI_OnLoad', 'Java_com_sun_jna_Native_getNativeVersion', 'Java_com_sun_jna_Native_getAPIChecksum'}
    if not required <= symbols or version.encode() + b'\0' not in data or checksum.encode() + b'\0' not in data:
        raise SystemExit('JNA native JNI exports/version/checksum missing')
    return dict(elfClass=elf_class, machine=machine, loadSegments=loads, requiredExports=sorted(required),
                sha256=digest(data), size=len(data))

if package.is_symlink() or not package.is_dir():
    raise SystemExit('JNA package directory must be regular')
pins_data = read(root / 'android/config/SOURCES.json')
pins = [row for row in json.loads(pins_data)['licenses'] if row['key'] == 'jna-libffi']
if len(pins) != 1:
    raise SystemExit('JNA source pin must be unique')
pin = pins[0]
tree_data = read(package / 'papercusp-android-dependency-sources/jna-NATIVE-TREE.json')
exec(os.environ['JNA_TREE_VALIDATION_CODE'])
tree_rows, selected = pinned_jna_tree(json.loads(tree_data), pin)
reference_data = read(package / 'papercusp-jna-source-result.json')
reference = json.loads(reference_data)
for key in ('sourceRevision', 'sourceTreeSha1'):
    if reference.get(key) != pin[key]:
        raise SystemExit('JNA package reference differs from current upstream pin: ' + key)
archive_path = package / 'papercusp-jna-source.tar.gz'
archive_data = read(archive_path)
if (reference.get('exitCode') != 0 or reference.get('schemaVersion') != 1 or
        reference['archive']['sha256'] != digest(archive_data) or reference['archive']['size'] != len(archive_data)):
    raise SystemExit('JNA package digest or successful reference differs')
rows = {}
for row in reference['files']:
    name = safe(row['path'])
    if name in rows:
        raise SystemExit('Duplicate JNA reference input: ' + name)
    rows[name] = row
if reference['verifiedFiles'] != len(rows) or set(rows) != set(selected):
    raise SystemExit('JNA reference input population differs')
files, modes = {}, {}
with tarfile.open(archive_path, 'r:gz') as archive:
    for entry in archive:
        name = safe(entry.name)
        if not name.startswith('papercusp-jna-source/'):
            raise SystemExit('JNA archive prefix differs')
        name = name.removeprefix('papercusp-jna-source/')
        if name in files or not entry.isfile() or entry.mode not in (0o644, 0o755):
            raise SystemExit('JNA archive has duplicate or unsafe input: ' + name)
        files[name] = archive.extractfile(entry).read()
        modes[name] = entry.mode
if set(files) != set(rows) | {'SOURCE-PROVENANCE.json'}:
    raise SystemExit('JNA archive input population differs from reference')
metadata = json.loads(files.pop('SOURCE-PROVENANCE.json'))
if metadata != {key: reference[key] for key in ('schemaVersion', 'sourceRevision', 'sourceTreeSha1', 'files', 'scope')}:
    raise SystemExit('JNA embedded provenance differs from reference')
for name, data in files.items():
    row = rows[name]
    original = selected[name]
    if (row['size'] != len(data) or row['sha256'] != digest(data) or row['gitBlob'] != blob(data) or
            original['sha'] != blob(data) or original['size'] != len(data) or
            modes[name] != (0o755 if original['mode'] == '100755' else 0o644)):
        raise SystemExit('JNA delivered source bytes differ: ' + name)
required = {'build.xml', 'common.xml', 'build-ant-tools.xml', 'native/Makefile',
            'LICENSE', 'AL2.0', 'LGPL2.1', 'OTHERS', 'native/libffi/LICENSE'}
if not required <= files.keys() or digest(files['native/libffi/LICENSE']) != pin['sourceSha256']:
    raise SystemExit('JNA required build/license inputs differ')
build, common, tools = (ET.fromstring(files[name]) for name in ('build.xml', 'common.xml', 'build-ant-tools.xml'))
targets = {target.attrib['name']: target for target in build.findall('target')}
if not {'compile', 'javah', 'native', 'native-build-package'} <= targets.keys():
    raise SystemExit('JNA root Ant build targets missing')
header_compilers = targets['compile'].findall('.//javac')
if not header_compilers or any(task.get('release') != '${javac.release}' or not task.get('nativeheaderdir') for task in header_compilers):
    raise SystemExit('JNA root JNI header generation recipe differs')
properties = {row.get('name'): row.get('value') for row in common.findall('property')}
if properties.get('javac.release') != '8' or not re.fullmatch('[0-9a-f]{32}', properties.get('jni.md5', '')):
    raise SystemExit('JNA Java release or JNI checksum input differs')
jni_version = '.'.join(properties.get('jni.' + part, '') for part in ('major', 'minor', 'revision'))
if not re.fullmatch(r'\d+\.\d+\.\d+', jni_version) or 'compile' not in targets['javah'].get('depends', '').split(','):
    raise SystemExit('JNA JNI version or header dependency differs')
tool_compilers = tools.findall('.//javac')
tool_paths = {'lib/ant.jar', 'lib/asm-8.0.1.jar'}
if not tool_compilers or any(set(task.get('classpath', '').split(':')) != tool_paths for task in tool_compilers):
    raise SystemExit('JNA Ant helper tool recipe differs')
tool_pins = pin.get('buildToolInputs', [])
if len(tool_pins) != 2 or {row['path'] for row in tool_pins} != tool_paths:
    raise SystemExit('JNA build tool references must be complete and unique')
tool_inputs = []
for row in tool_pins:
    name = safe(row['path'])
    original = tree_rows.get(name, {})
    if (not re.fullmatch('[0-9a-f]{40}', row['gitBlob']) or type(row['size']) is not int or row['size'] <= 0 or
            original.get('type') != 'blob' or original.get('sha') != row['gitBlob'] or original.get('size') != row['size']):
        raise SystemExit('JNA build tool reference invalid: ' + name)
    path = package / name
    if path.is_symlink() or path.parent.is_symlink():
        raise SystemExit('JNA build tool must not be a symlink: ' + name)
    entry = dict(row, status='missing')
    if path.exists():
        data = read(path)
        if len(data) != row['size'] or blob(data) != row['gitBlob']:
            raise SystemExit('JNA supplied build tool differs from pinned blob: ' + name)
        entry.update(status='supplied-blob-verified', sha256=digest(data))
    tool_inputs.append(entry)
    configured = None
if mode == 'jna-configure':
    if any(row['status'] == 'missing' for row in tool_inputs):
        raise SystemExit('JNA configuration requires both pinned helper JARs')
    # These root templates are outside the retained selected archive, but the
    # unmodified root Ant route copies them before compiling its JNI headers.
    recipe_inputs = []
    for name in ('pom-jna.xml', 'pom-jna-platform.xml', 'pom-jna-jpms.xml', 'pom-jna-platform-jpms.xml'):
        original = tree_rows.get(name, {})
        data = read(package / name)
        if original.get('type') != 'blob' or original.get('sha') != blob(data) or original.get('size') != len(data):
            raise SystemExit('JNA supplied root template differs from pinned blob: ' + name)
        recipe_inputs.append(dict(path=name, gitBlob=blob(data), sha256=digest(data), size=len(data)))
    java_home = Path(os.environ.get('JAVA_HOME', '')).resolve()
    ant_home = Path(os.environ.get('ANT_HOME', '')).resolve()
    if not os.environ.get('JAVA_HOME') or not os.environ.get('ANT_HOME'):
        raise SystemExit('JNA configuration requires explicit JAVA_HOME and ANT_HOME')
    executables = [java_home / 'bin' / name for name in ('java', 'javac')]
    jars = []
    for pattern in ('ant.jar', 'ant-launcher.jar'):
        candidates = [ant_home / 'lib' / pattern]
        if not candidates[0].is_file():
            candidates = sorted((ant_home / 'lib').glob(pattern.removesuffix('.jar') + '-[0-9]*.jar'))
        if len(candidates) != 1:
            raise SystemExit('JNA Ant runtime JAR must resolve uniquely: ' + pattern)
        jars.append(candidates[0])
    expected_runtime = pin.get('configurationRuntimeInputs', [])
    if len(expected_runtime) != 2:
        raise SystemExit('JNA Ant execution runtime pins must be complete')
    for path in jars:
        data = read(path)
        if not any(row.get('size') == len(data) and row.get('sha256') == digest(data) for row in expected_runtime):
            raise SystemExit('JNA Ant execution runtime differs from pinned input: ' + str(path))
    runtime_inputs = []
    for path in executables + jars:
        # JDK executable symlinks are conventional; fingerprint their actual
        # targets and retain both paths instead of rejecting normal JDK installs.
        resolved = path.resolve(strict=True)
        data = read(resolved)
        runtime_inputs.append(dict(path=str(path), resolvedPath=str(resolved), sha256=digest(data), size=len(data)))
    environment = os.environ.copy()
    for key in ('JAVA_TOOL_OPTIONS', '_JAVA_OPTIONS', 'JDK_JAVA_OPTIONS', 'ANT_OPTS', 'ANT_ARGS', 'CLASSPATH'):
        environment.pop(key, None)
    versions = {}
    for path in executables:
        completed = subprocess.run([str(path), '-version'], env=environment, capture_output=True, text=True, check=True)
        versions[path.name] = (completed.stdout + completed.stderr).strip()
    classpath = os.pathsep.join(map(str, jars))
    ant_command = [str(executables[0]), '-cp', classpath, 'org.apache.tools.ant.Main']
    completed = subprocess.run(ant_command + ['-version'], env=environment, capture_output=True, text=True, check=True)
    versions['ant'] = (completed.stdout + completed.stderr).strip()
    output_dir = root / 'android/app/build/outputs'
    run_id = started.replace(':', '').replace('+', '').replace('.', '')
    work = Path(tempfile.mkdtemp(prefix='papercusp-jna-configure-', dir=output_dir))
    source = work / 'source'
    source.mkdir()
    included_native_sources, excluded_native_sources = jna_configured_native_files(build, files)
    # Materialize only the validated regular files, never tar.extractall().
    for name, data in files.items():
        path = source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(modes[name])
    for row in tool_inputs + recipe_inputs:
        path = source / row['path']
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(read(package / row['path']))
    packages = []
    for abi, prefix, arch in (('armeabi-v7a', 'android-armv7', 'armv7'), ('arm64-v8a', 'android-aarch64', 'aarch64'),
                               ('x86', 'android-x86', 'x86'), ('x86_64', 'android-x86-64', 'x86-64')):
        command = ant_command + ['-f', 'build.xml', '-Drelease=true', '-Dbuild-native=true',
                                 '-Dos.prefix=' + prefix, '-DARCH=' + arch, 'native-build-package']
        log = output_dir / ('papercusp-jna-configure-' + run_id + '-' + abi + '.log')
        with log.open('wb') as stream:
            completed = subprocess.run(command, cwd=source, env=environment, stdout=stream, stderr=subprocess.STDOUT)
        if completed.returncode:
            raise SystemExit('JNA upstream configuration failed for ' + abi + '; retained log: ' + str(log))
        build_dir = source / 'build'
        headers = sorted((build_dir / 'headers').glob('*.h'))
        properties_file = build_dir / 'headers/jni.properties'
        properties_text = read(properties_file, remember=False).decode()
        generated_properties = dict(line.split('=', 1) for line in properties_text.splitlines()
                                    if line and not line.startswith('#') and '=' in line)
        if (not headers or generated_properties.get('version') != jni_version or
                generated_properties.get('checksum') != properties['jni.md5']):
            raise SystemExit('JNA generated header version/checksum differs from pinned recipe')
        script = read(build_dir / 'build.sh', remember=False)
        for expected in ('OS=android', 'ARCH=' + arch, 'JNA_JNI_VERSION=' + jni_version, 'CHECKSUM=' + properties['jni.md5']):
            if expected.encode() not in script:
                raise SystemExit('JNA configured build script omits expected input: ' + expected)
        filename = 'build-package-' + prefix + '-' + jni_version + '.zip'
        package_bytes = read(build_dir / filename)
        destination = output_dir / ('papercusp-jna-configured-' + run_id + '-' + filename)
        destination.write_bytes(package_bytes)
        with zipfile.ZipFile(destination) as archive:
            names = archive.namelist()
            if len(names) != len(set(names)):
                raise SystemExit('JNA configured archive has duplicate entries')
            archive_prefix = filename.removesuffix('.zip') + '/'
            for name in names:
                safe(name.rstrip('/'))
                if not name.startswith(archive_prefix):
                    raise SystemExit('JNA configured archive has unexpected prefix')
            expected_bytes = {'build.sh': script}
            expected_bytes.update({'headers/' + str(path.relative_to(build_dir / 'headers')): read(path, remember=False)
                                   for path in sorted((build_dir / 'headers').rglob('*')) if path.is_file()})
            expected_bytes.update(included_native_sources)
            actual_native = {name.removeprefix(archive_prefix) for name in names
                             if name.startswith(archive_prefix + 'native/') and not name.endswith('/')}
            if actual_native != {name for name in expected_bytes if name.startswith('native/')}:
                raise SystemExit('JNA configured archive native-source population differs from upstream exclusions')
            for name, data in expected_bytes.items():
                if archive.read(archive_prefix + name) != data:
                    raise SystemExit('JNA configured archive input differs: ' + name)
        packages.append(dict(abi=abi, osPrefix=prefix, makeArch=arch, command=command, logPath=str(log),
                             logSha256=digest(read(log)), archivePath=str(destination), archiveSha256=digest(package_bytes),
                             archiveSize=len(package_bytes), verifiedArchiveFiles=len(expected_bytes),
                             buildScriptSha256=digest(script), headers=[dict(path=path.name, sha256=digest(read(path, remember=False))) for path in headers],
                             jniVersion=generated_properties['version'], jniChecksum=generated_properties['checksum']))
    configured = dict(recipeInputs=recipe_inputs, runtimeInputs=runtime_inputs, runtimeVersions=versions,
                      workPath=str(work), packages=packages, upstreamExcludedNativeSources=excluded_native_sources,
                      javaCompilationExecuted=True, generatedHeadersVerified=True,
                      nativeCompilationExecuted=False, nativeExecutionPerformed=False)
native = None
if mode == 'jna-native':
    configuration_data = read(package / 'papercusp-jna-configure-result.json')
    configuration = json.loads(configuration_data)
    if (configuration.get('exitCode') != 0 or configuration.get('mode') != 'jna-configure' or
            any(configuration.get(key) != value for key, value in
                (('sourceRevision', pin['sourceRevision']), ('sourceTreeSha1', pin['sourceTreeSha1']),
                 ('archiveSha256', digest(archive_data)), ('inputTreeSha256', digest(tree_data)),
                 ('inputPinsSha256', digest(pins_data))))):
        raise SystemExit('JNA configured receipt differs from validated source inputs')
    abi_specs = {'arm64-v8a': ('aarch64', 'aarch64-linux-android', 2, 183),
                 'armeabi-v7a': ('armv7', 'armv7a-linux-androideabi', 1, 40),
                 'x86': ('x86', 'i686-linux-android', 1, 3),
                 'x86_64': ('x86-64', 'x86_64-linux-android', 2, 62)}
    wanted = list(abi_specs) if sys.argv[4] == 'all' else [sys.argv[4]]
    if any(abi not in abi_specs for abi in wanted):
        raise SystemExit('JNA native ABI must be all, arm64-v8a, armeabi-v7a, x86 or x86_64')
    output_dir = root / 'android/app/build/outputs'
    work = Path(tempfile.mkdtemp(prefix='papercusp-jna-native-', dir=output_dir))
    native = dict(workPath=str(work), configurationReceiptSha256=digest(configuration_data),
                  packages=[], phase='preflight', exitCode=1, nativeExecutionPerformed=False,
                  originalInvocationVerified=False, candidateComparisonPerformed=False, recipientRetrievalVerified=False)
    try:
        environment = dict(os.environ)
        for name in ('MAKEFLAGS', 'MFLAGS', 'MAKEOVERRIDES', 'CC', 'CPP', 'LD', 'AR', 'RANLIB', 'STRIP',
                     'CFLAGS', 'CPPFLAGS', 'LDFLAGS', 'LIBS', 'CONFIG_SITE', 'MAKEINFO', 'AUTORECONF',
                     'AUTOCONF', 'AUTOMAKE', 'ACLOCAL', 'AUTOHEADER', 'LIBTOOLIZE', 'M4', 'PERL'):
            environment.pop(name, None)
        environment['CONFIG_SITE'] = '/dev/null'
        if not environment.get('ANDROID_NDK_HOME'):
            raise SystemExit('JNA native requires explicit ANDROID_NDK_HOME')
        tools, llvm, sysroot = jna_native_preflight(environment, Path(environment['ANDROID_NDK_HOME']).resolve())
        for tool in tools:
            if digest(read(Path(tool['path']))) != tool['sha256']:
                raise SystemExit('JNA native host tool changed during preflight: ' + tool['name'])
        native.update(hostTools=tools, ndkSourcePropertiesSha256=digest(read(llvm.parents[3] / 'source.properties')),
                      sysroot=str(sysroot), jniHeaderSha256=digest(read(sysroot / 'usr/include/jni.h')), toolchainInputs=[])
        paths = {tool['name']: tool['path'] for tool in tools}
        prepared = []
        included, excluded = jna_configured_native_files(build, files)
        for abi in wanted:
            arch, triple, elf_class, machine = abi_specs[abi]
            compiler = llvm / ('bin/' + triple + '24-clang')
            for name, path in [('clang', compiler), ('ar', llvm / 'bin/llvm-ar'),
                               ('ranlib', llvm / 'bin/llvm-ranlib'), ('strip', llvm / 'bin/llvm-strip'),
                               ('readelf', llvm / 'bin/llvm-readelf'), ('clang-backend', llvm / 'bin/clang'),
                               ('linker', llvm / 'bin/ld.lld')]:
                if not path.is_file() or not os.access(path, os.X_OK):
                    raise SystemExit('JNA native NDK executable missing: ' + str(path))
                completed = subprocess.run([str(path), '--version'], capture_output=True, text=True, env=environment, check=True)
                native['toolchainInputs'].append(dict(abi=abi, name=name, path=str(path),
                    resolvedPath=str(path.resolve()), sha256=digest(read(path.resolve())),
                    version=(completed.stdout + completed.stderr).strip()))
            if not (sysroot / 'usr/lib' / ('arm-linux-androideabi' if abi == 'armeabi-v7a' else triple) / '24/libc.so').is_file():
                raise SystemExit('JNA native NDK API 24 sysroot library missing: ' + abi)
            native['toolchainInputs'].append(dict(abi=abi, name='api24-libc',
                sha256=digest(read(sysroot / 'usr/lib' / ('arm-linux-androideabi' if abi == 'armeabi-v7a' else triple) / '24/libc.so'))))
            matches = [row for row in configuration['configuration']['packages'] if row['abi'] == abi]
            if len(matches) != 1 or matches[0]['makeArch'] != arch or matches[0]['osPrefix'] != 'android-' + arch:
                raise SystemExit('JNA configured ABI population differs: ' + abi)
            row = matches[0]
            archive = Path(row['archivePath'])
            # Receipts produced elsewhere are portable by basename in package_dir.
            if not archive.is_file():
                archive = package / archive.name
            data = read(archive)
            if digest(data) != row['archiveSha256'] or len(data) != row['archiveSize']:
                raise SystemExit('JNA configured ZIP digest differs: ' + abi)
            abi_work = work / abi
            abi_work.mkdir()
            with zipfile.ZipFile(archive) as zipped:
                members = [item for item in zipped.infolist() if not item.is_dir()]
                entries = {}
                for item in members:
                    safe(item.filename)
                    name = '/'.join(item.filename.split('/')[1:])
                    if not name or name in entries or ((item.external_attr >> 16) & 0o170000) not in (0, 0o100000):
                        raise SystemExit('JNA configured ZIP unsafe member')
                    entries[name] = zipped.read(item)
                if {name for name in entries if name.startswith('native/')} != set(included):
                    raise SystemExit('JNA configured native population differs')
                if any(entries[name] != data for name, data in included.items()):
                    raise SystemExit('JNA configured native bytes differ')
                stub_name = row['osPrefix'] + '.jar'
                jna_native_headers(entries, row['headers'], jni_version, properties['jni.md5'])
                generated_names = {'headers/' + header['path'] for header in row['headers']} | {
                    'headers/jni.properties', 'headers/jni.checksum', 'headers/jni.checksum.error'}
                if set(entries) != set(included) | generated_names | {'build.sh', stub_name}:
                    raise SystemExit('JNA configured generated-input population differs')
                jna_native_stub(entries[stub_name], jni_version)
                if digest(entries['build.sh']) != row['buildScriptSha256']:
                    raise SystemExit('JNA configured script fingerprint differs')
                for name, data in entries.items():
                    path = abi_work / safe(name)
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(data)
                    path.chmod(0o755 if name.startswith('native/') and modes[name] == 0o755 else 0o644)
            (abi_work / 'build').mkdir()
            prepared.append((abi, arch, compiler, elf_class, machine, abi_work, row))
        native['phase'] = 'native-make'
        for abi, arch, compiler, elf_class, machine, abi_work, row in prepared:
            command = jna_native_command(paths['make'], llvm, abi_work, arch, compiler, jni_version, properties['jni.md5'])
            log = abi_work / 'native-build.log'
            outcome = dict(abi=abi, archiveSha256=row['archiveSha256'], command=command,
                           logPath=str(log), exitCode=None)
            native['packages'].append(outcome)
            with log.open('wb') as stream:
                completed = subprocess.run(command, cwd=abi_work / 'native', env=environment,
                                           stdout=stream, stderr=subprocess.STDOUT)
            outcome.update(exitCode=completed.returncode, logSha256=digest(log.read_bytes()))
            config = abi_work / 'build/libffi/config.log'
            if config.is_file():
                outcome.update(configLogPath=str(config), configLogSha256=digest(config.read_bytes()))
            if completed.returncode:
                raise SystemExit('JNA native make failed for ' + abi + '; retained log: ' + str(log))
            library = abi_work / 'build/libjnidispatch.so'
            if not library.is_file() or library.is_symlink():
                raise SystemExit('JNA native make produced no regular dispatcher: ' + abi)
            outcome['library'] = dict(path=str(library), **jna_native_elf(library, elf_class, machine,
                                     llvm / 'bin/llvm-readelf', jni_version, properties['jni.md5']))
        native.update(exitCode=0, phase='verified-elf')
    except BaseException as error:
        native['error'] = str(error)
        raise
    finally:
        native['finishedAt'] = datetime.now(timezone.utc).isoformat()
        (work / 'native-build-result.json').write_text(json.dumps(native, indent=2) + '\n')
if any(read(path) != data for path, data in list(snapshots.items())):
    raise SystemExit('JNA inputs changed during verification')
if subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD']).decode().strip() != commit or subprocess.check_output(
        ['git', '-C', str(root), 'status', '--porcelain', '--untracked-files=normal']).strip():
    raise SystemExit('Mobile source changed during JNA input verification')
result = {
    'schemaVersion': 1, 'mode': mode, 'exitCode': 0, 'startedAt': started,
    'finishedAt': datetime.now(timezone.utc).isoformat(), 'mobileSourceCommit': commit,
    'sourceRevision': pin['sourceRevision'], 'sourceTreeSha1': pin['sourceTreeSha1'],
    'archiveSha256': digest(archive_data), 'referenceSha256': digest(reference_data),
    'inputTreeSha256': digest(tree_data),
    'inputPinsSha256': digest(pins_data), 'verifiedFiles': len(files),
    'producerSha256': digest(read(root / 'tools/build-scripts/android-release-provenance.sh')),
    'buildInputs': [rows[name] for name in sorted(required)],
    'rootRecipe': {'javacRelease': properties['javac.release'], 'jniVersion': jni_version,
                   'jniChecksum': properties['jni.md5'], 'targets': sorted(set(targets) & {'compile', 'javah', 'native', 'native-build-package'})},
    'externalToolInputs': tool_inputs, 'buildExecuted': False, 'originalInvocationVerified': False,
    'standaloneToolchainVerified': False, 'recipientRetrievalVerified': False,
    'remaining': ['Java/Ant/native toolchain and chosen invocation', 'generated headers and configured build script',
                  'actual native build and exact-candidate comparison', 'original prebuilt invocation and license election',
                  'recipient retrieval'],
    'scope': 'Offline local consumption of a retained selected source package and root recipe inputs, not a native build, complete toolchain, rights or recipient-delivery proof.'
}
result['remaining'][:0] = [row['path'] for row in tool_inputs if row['status'] == 'missing']
if configured is not None:
    result['configuration'] = configured
    result['remaining'] = ['native toolchain and actual dispatcher compilation', 'original prebuilt invocation and license election',
                           'exact-candidate comparison and recipient retrieval/build']
    result['scope'] = 'Local pinned-source upstream Ant Java/header and four-ABI build-package preparation, without native compilation/execution, original invocation, rights, candidate or recipient proof.'
if native is not None:
    result['native'] = native
    result.update(buildExecuted=True, standaloneToolchainVerified=True)
    result['remaining'] = ['original prebuilt invocation and license election', 'complete source/notice rights',
                           'exact-candidate comparison', 'native execution', 'recipient retrieval/build']
    result['scope'] = 'Local retained configured-source dispatcher compilation and ELF validation for the listed ABIs; no native execution, original invocation, rights, candidate or recipient proof.'
receipt_name = {'jna-configure': 'papercusp-jna-configure-result.json', 'jna-native': 'papercusp-jna-native-result.json'}.get(mode, 'papercusp-jna-build-inputs-result.json')
(root / 'android/app/build/outputs' / receipt_name).write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
PY
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
        if [[ "${2:-}" == jna ]]; then
            [[ $# -le 3 ]] || die "usage: $0 source-archive jna [source-directory]"
            source_archive_jna "${3:-$REPO_ROOT/android/app/build/outputs/papercusp-android-dependency-sources/jna-5.19.1-source}"
        else
            [[ $# -eq 1 ]] || die "usage: $0 source-archive [jna [source-directory]]"
            assert_clean_source
            commit="$(source_commit)"
            source_archive write "$commit"
            source_archive verify "$commit"
            printf '%s\n' "$REPO_ROOT/$SOURCE_REL"
        fi
        ;;
    source-verify-build)
        [[ $# -le 4 ]] || die "usage: $0 source-verify-build [host|android|android-apk|jna-inputs|jna-configure|jna-native [package-directory [abi]]]"
        mode="${2:-host}"
        if [[ "$mode" == jna-inputs || "$mode" == jna-configure || "$mode" == jna-native ]]; then
            [[ "$mode" == jna-native || $# -le 3 ]] || die 'abi selection is only supported for jna-native'
            verify_jna_inputs "${3:-$REPO_ROOT/android/app/build/outputs}" "$mode" "${4:-all}"
        else
            [[ $# -le 2 && ( "$mode" == host || "$mode" == android || "$mode" == android-apk ) ]] || die "source build mode must be host, android, android-apk, jna-inputs or jna-configure"
            verify_source_build "$mode"
        fi
        ;;
    source-notices)
        [[ $# -eq 1 ]] || die "usage: $0 source-notices"
        verify_source_build notices
        ;;
    *)
        die "usage: $0 {write <version> [apk] [aab]|verify <version>|render|path|record|source-archive [jna [source-directory]]|source-notices|source-verify-build [host|android|android-apk|jna-inputs|jna-configure|jna-native [package-directory [abi]]]}"
        ;;
esac

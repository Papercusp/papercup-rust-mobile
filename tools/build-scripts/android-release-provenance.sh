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
    *)
        die "usage: $0 {write <version> [apk] [aab]|verify <version>|render|path|record|source-archive}"
        ;;
esac

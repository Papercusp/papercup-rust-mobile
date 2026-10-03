#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/tools/build-scripts/android-release-provenance.sh"
GRADLE="$ROOT/android/app/build.gradle.kts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$TMP-submodule" "$TMP-nested"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -F 'versionCode = androidVersionCode(releaseVersion)' "$GRADLE" >/dev/null \
    || fail 'Gradle versionCode no longer derives from PAPERCUP_RELEASE_VERSION'
if grep -Eq '^[[:space:]]*versionCode[[:space:]]*=[[:space:]]*1[[:space:]]*$' "$GRADLE"; then
    fail 'Gradle versionCode regressed to a hardcoded 1'
fi

git -C "$TMP" init -q
git -C "$TMP" config user.name test
git -C "$TMP" config user.email test@example.invalid
printf '/android/app/build/\n/bin/\n' >"$TMP/.gitignore"
printf 'source\n' >"$TMP/source.txt"
printf 'test license\n' >"$TMP/LICENSE"
LONG_DIR="$(printf 'long-directory-%.0s' {1..8})"
mkdir -p "$TMP/$LONG_DIR"
printf 'long path source\n' >"$TMP/$LONG_DIR/source.txt"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/build.sh"
chmod +x "$TMP/build.sh"
ln -s source.txt "$TMP/source-link"
git -C "$TMP" add .gitignore source.txt LICENSE "$LONG_DIR/source.txt" build.sh source-link
git -C "$TMP" commit -qm initial

# Local, recursively pinned submodules exercise real gitlinks without network
# access. Their files and licenses must survive source export; root git archive
# alone silently omits them. Ignored local credentials must remain excluded.
for repo in "$TMP-submodule" "$TMP-nested"; do
    git -C "$(dirname "$repo")" init -q "$repo"
    git -C "$repo" config user.name test
    git -C "$repo" config user.email test@example.invalid
    printf 'submodule source\n' >"$repo/source.txt"
    printf 'submodule license\n' >"$repo/LICENSE"
    git -C "$repo" add source.txt LICENSE
    git -C "$repo" commit -qm initial
done
git -C "$TMP-submodule" -c protocol.file.allow=always submodule add -q "$TMP-nested" nested
git -C "$TMP-submodule" commit -qam nested
git -C "$TMP" -c protocol.file.allow=always submodule add -q "$TMP-submodule" libs/token-kit
git -C "$TMP" -c protocol.file.allow=always submodule update --init --recursive -q
git -C "$TMP" commit -qam submodule

APK="$TMP/android/app/build/outputs/apk/release/app-release.apk"
AAB="$TMP/android/app/build/outputs/bundle/release/app-release.aab"
mkdir -p "$(dirname "$APK")" "$(dirname "$AAB")" "$TMP/bin"
printf 'private local credential\n' >"$TMP/bin/secret.txt"
dd if=/dev/zero of="$APK" bs=1024 count=2 status=none
printf 'apk' | dd of="$APK" conv=notrunc status=none
dd if=/dev/zero of="$AAB" bs=1024 count=3 status=none
printf 'aab' | dd of="$AAB" conv=notrunc status=none

cat >"$TMP/bin/apkanalyzer" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in
    version-name) printf '%s\n' "${FAKE_APK_VERSION:-0.0.17}" ;;
    version-code) printf '%s\n' "${FAKE_APK_VERSION_CODE:-17}" ;;
    *) exit 2 ;;
esac
SH
chmod +x "$TMP/bin/apkanalyzer"

run_helper() {
    PAPERCUP_MOBILE_ROOT="$TMP" PAPERCUP_APKANALYZER="$TMP/bin/apkanalyzer" "$HELPER" "$@"
}

run_helper write 0.0.17 "$APK" "$AAB" >/dev/null
run_helper verify 0.0.17 >/dev/null

MANIFEST="$TMP/android/app/build/outputs/papercusp-release-provenance.json"
node - "$MANIFEST" "$APK" "$AAB" "$(git -C "$TMP" rev-parse HEAD)" <<'NODE'
const crypto = require('node:crypto');
const fs = require('node:fs');
const [manifestFile, apk, aab, commit] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
const hash = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
if (manifest.schemaVersion !== 1 || manifest.releaseVersion !== '0.0.17' || manifest.versionCode !== 17) process.exit(1);
if (manifest.sourceCommit !== commit || manifest.sourceDirty !== false) process.exit(1);
if (manifest.artifacts.apk.sha256 !== hash(apk) || manifest.artifacts.aab.sha256 !== hash(aab)) process.exit(1);
const source = manifest.artifacts.source;
if (!source || source.path !== 'android/app/build/outputs/papercusp-mobile-source.tar.gz') process.exit(1);
NODE

SOURCE="$TMP/android/app/build/outputs/papercusp-mobile-source.tar.gz"
python3 - "$SOURCE" <<'PY'
import json
import sys
import tarfile
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    names = set(archive.getnames())
    prefix = 'papercusp-mobile-source/'
    required = {'source.txt', 'LICENSE', 'libs/token-kit/source.txt',
                'libs/token-kit/LICENSE', 'libs/token-kit/nested/source.txt',
                'libs/token-kit/nested/LICENSE', 'SOURCE-PROVENANCE.json'}
    assert {prefix + name for name in required} <= names
    assert not any('/bin/' in name or '/.git/' in name for name in names)
    assert archive.getmember(prefix + 'build.sh').mode & 0o111
    assert archive.getmember(prefix + 'source-link').issym()
    assert archive.getmember(prefix + 'source-link').linkname == 'source.txt'
    assert any(len(name) > 100 and name.endswith('/source.txt') for name in names)
    identity = json.load(archive.extractfile(prefix + 'SOURCE-PROVENANCE.json'))
    assert [repo['path'] for repo in identity['repositories']] == ['.', 'libs/token-kit', 'libs/token-kit/nested']
PY
SOURCE_SHA="$(sha256sum "$SOURCE" | awk '{print $1}')"
run_helper source-archive >/dev/null
[[ "$(sha256sum "$SOURCE" | awk '{print $1}')" == "$SOURCE_SHA" ]] || fail 'same pinned source did not produce reproducible archive bytes'
run_helper verify 0.0.17 >/dev/null

# Even an attacker-updated manifest hash cannot make incomplete source valid.
cp "$SOURCE" "$TMP/bin/source-backup.tar.gz"
cp "$MANIFEST" "$TMP/bin/manifest-backup.json"
python3 - "$SOURCE" "$MANIFEST" <<'PY'
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
source, manifest = map(Path, sys.argv[1:])
entries = []
with tarfile.open(source, 'r:gz') as archive:
    for member in archive:
        if member.name.endswith('nested/source.txt'):
            continue
        entries.append((member, archive.extractfile(member).read() if member.isfile() else None))
with tarfile.open(source, 'w:gz') as archive:
    for member, data in entries:
        archive.addfile(member, io.BytesIO(data) if data is not None else None)
record = json.loads(manifest.read_text())
record['artifacts']['source'].update(size=source.stat().st_size, sha256=hashlib.sha256(source.read_bytes()).hexdigest())
manifest.write_text(json.dumps(record))
PY
if run_helper verify 0.0.17 >/dev/null 2>&1; then
    fail 'incomplete submodule source with updated manifest hash passed verification'
fi
cp "$TMP/bin/source-backup.tar.gz" "$SOURCE"
cp "$TMP/bin/manifest-backup.json" "$MANIFEST"
run_helper verify 0.0.17 >/dev/null

mv "$TMP/libs/token-kit" "$TMP/bin/token-kit"
if run_helper source-archive >/dev/null 2>&1; then fail 'uninitialized submodule produced source archive'; fi
mv "$TMP/bin/token-kit" "$TMP/libs/token-kit"
printf 'dirty\n' >>"$TMP/libs/token-kit/source.txt"
if run_helper source-archive >/dev/null 2>&1; then fail 'dirty submodule produced source archive'; fi
git -C "$TMP/libs/token-kit" checkout -- source.txt
git -C "$TMP/libs/token-kit" checkout -q HEAD~1
if run_helper source-archive >/dev/null 2>&1; then fail 'submodule HEAD differs from pinned gitlink but produced source archive'; fi
git -C "$TMP/libs/token-kit" checkout -q "$(git -C "$TMP" rev-parse HEAD:libs/token-kit)"
run_helper verify 0.0.17 >/dev/null

# export-ignore is not allowed to omit source silently; export-subst must not
# rewrite the bytes that the recorded commit identifies.
printf 'source.txt export-ignore\n' >"$TMP/.gitattributes"
git -C "$TMP" add .gitattributes
git -C "$TMP" commit -qm export-ignore
if run_helper source-archive >/dev/null 2>&1; then fail 'export-ignore silently omitted source'; fi
printf 'source.txt export-subst\n' >"$TMP/.gitattributes"
printf '$Format:%%H$\n' >"$TMP/source.txt"
git -C "$TMP" add .gitattributes source.txt
git -C "$TMP" commit -qm export-subst
if run_helper source-archive >/dev/null 2>&1; then fail 'export-subst silently rewrote source bytes'; fi
git -C "$TMP" rm -q .gitattributes
printf 'source\n' >"$TMP/source.txt"
git -C "$TMP" add source.txt
git -C "$TMP" commit -qm restore-source
run_helper write 0.0.17 "$APK" "$AAB" >/dev/null

# The candidate record must be GENERATED into gitignored build output, and
# generating it must not disturb the clean tree / HEAD binding that provenance
# depends on. A tracked record cannot satisfy both at once, which is the defect
# this guards: refreshing it dirtied the tree (verify fails at assert_clean_source)
# and committing it moved HEAD (verify fails on sourceCommit mismatch).
RECORD="$TMP/android/app/build/outputs/RELEASE-CANDIDATE.md"
[[ -f "$RECORD" ]] || fail 'release write did not generate the candidate record'
[[ "$(run_helper record)" == "$RECORD" ]] || fail 'record subcommand printed the wrong path'

APK_SHA="$(sha256sum "$APK" | awk '{print $1}')"
AAB_SHA="$(sha256sum "$AAB" | awk '{print $1}')"
grep -Fq "$APK_SHA" "$RECORD" || fail 'generated record does not carry the APK SHA-256'
grep -Fq "$AAB_SHA" "$RECORD" || fail 'generated record does not carry the AAB SHA-256'
grep -Fq '0.0.17' "$RECORD" || fail 'generated record does not carry the release version'

RENDER_DIRT="$(git -C "$TMP" status --porcelain --untracked-files=normal)"
[[ -z "$RENDER_DIRT" ]] \
    || fail "generating the candidate record dirtied the source tree: $RENDER_DIRT"
run_helper verify 0.0.17 >/dev/null \
    || fail 'provenance stopped verifying once the candidate record was generated'

run_helper render >/dev/null || fail 'standalone render failed'
run_helper verify 0.0.17 >/dev/null || fail 'provenance stopped verifying after a re-render'

# Recurrence guard: the TRACKED record must never regain per-build artifact
# identity. If it does, refreshing it after a build becomes mandatory again and
# the clean-tree/HEAD-binding rule above becomes unsatisfiable.
TRACKED_RECORD="${PAPERCUP_TRACKED_RECORD:-$ROOT/store/RELEASE-CANDIDATE.md}"
[[ -f "$TRACKED_RECORD" ]] || fail "tracked candidate record missing: $TRACKED_RECORD"
grep -Fq 'android/app/build/outputs/RELEASE-CANDIDATE.md' "$TRACKED_RECORD" \
    || fail 'tracked candidate record no longer points at the generated record'
while IFS= read -r pattern; do
    [[ -n "$pattern" ]] || continue
    if grep -Eiq "$pattern" "$TRACKED_RECORD"; then
        fail "tracked candidate record reintroduced per-build state (/$pattern/): it belongs in the generated record, which is untracked"
    fi
done <<'PATTERNS'
^\|[[:space:]]*(APK|AAB)[[:space:]]+(SHA-256|size)[[:space:]]*\|
replaces the hashes
PATTERNS

# Compile a real tiny cdylib and locked dependency from the delivered archives.
mkdir -p "$TMP/src"
cat >"$TMP/Cargo.toml" <<'TOML'
[package]
name = "papercup-bindings"
version = "0.1.0"
edition = "2021"
[lib]
name = "papercup"
crate-type = ["cdylib"]
[dependencies]
source_proof_dependency = "=1.0.0"
TOML
printf '#[no_mangle]\npub extern "C" fn delivered_value() -> u32 { source_proof_dependency::value() }\n' >"$TMP/src/lib.rs"
cat >"$TMP/Cargo.lock" <<'LOCK'
version = 3
[[package]]
name = "papercup-bindings"
version = "0.1.0"
dependencies = ["source_proof_dependency"]
[[package]]
name = "source_proof_dependency"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "abababababababababababababababababababababababababababababababab"
LOCK
git -C "$TMP" add Cargo.toml Cargo.lock src/lib.rs
git -C "$TMP" commit -qm source-build-fixture
run_helper write 0.0.17 "$APK" "$AAB" >/dev/null

DEPENDENCIES="$TMP/android/app/build/outputs/papercusp-rust-dependencies.tar.gz"
python3 - "$TMP" "$DEPENDENCIES" <<'PY'
import hashlib, io, json
from pathlib import Path
import sys, tarfile
root, output = map(Path, sys.argv[1:])
prefix = 'papercusp-mobile-source/'
vendor = 'android/app/build/outputs/papercusp-rust-dependencies'
files = {'Cargo.toml': b'[package]\nname="source_proof_dependency"\nversion="1.0.0"\nedition="2021"\nlicense="MIT"\n',
         'src/lib.rs': b'pub fn value() -> u32 { 42 }\n',
         'LICENSE': b'Fixture permission text\r\nCopyright fixture author\r\n',
         'AUTHORS': b'Fixture authors and additional attribution\n',
         'NOTICES.md': b'Plural notices with another attribution\n',
         '.cargo_vcs_info.json': json.dumps({'git': {'sha1': 'cd' * 20}}).encode()}
notice_files = [{'path': 'source_proof_dependency-1.0.0/' + name,
                 'sha256': hashlib.sha256(files[name]).hexdigest()} for name in ('AUTHORS', 'LICENSE', 'NOTICES.md')]
supplement=b'Full revision-pinned supplemental notice\n'
checksum = 'ab' * 32
files['.cargo-checksum.json'] = json.dumps({'package': checksum, 'files': {
    name: hashlib.sha256(data).hexdigest() for name, data in files.items()}}).encode()
entries = {vendor + '/source_proof_dependency-1.0.0/' + name: data for name, data in files.items()}
entries[vendor + '-provenance.json'] = json.dumps({
    'cargoLockSha256': hashlib.sha256((root/'Cargo.lock').read_bytes()).hexdigest(),
    'packages': [{'name': 'source_proof_dependency', 'version': '1.0.0', 'packageChecksum': checksum,
                  'declaredLicense': 'MIT', 'declaredLicenseFile': None, 'noticeFiles': notice_files,
                  'licenseSupplement': {'path': 'papercusp-rust-license-supplements/fixture.txt',
                                        'sha256': hashlib.sha256(supplement).hexdigest(),
                                        'sourceRevision': 'cd' * 20,
                                        'source': 'https://example.invalid/' + 'cd' * 20 + '/LICENSE'}}]}).encode()
entries['android/app/build/outputs/papercusp-rust-license-supplements/fixture.txt']=supplement
entries['.cargo/config.toml'] = ('[source.crates-io]\nreplace-with="vendored-sources"\n'
                               '[source.vendored-sources]\ndirectory="' + vendor + '"\n').encode()
with tarfile.open(output, 'w:gz') as archive:
    for name, data in entries.items():
        entry = tarfile.TarInfo(prefix + name); entry.size = len(data)
        archive.addfile(entry, io.BytesIO(data))
PY
cp "$DEPENDENCIES" "$TMP/bin/dependencies-backup.tar.gz"
run_helper source-verify-build host >"$TMP/bin/source-build-pass.json"
BUILD_RESULT="$TMP/android/app/build/outputs/papercusp-source-build-result.json"
python3 - "$BUILD_RESULT" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
assert result['exitCode']==0 and result['verifiedRegistryPackages']==1 and result['verifiedVendorFiles']==6
assert len(result['compiledArtifacts'])==1 and result['compiledArtifacts'][0]['size']>0
assert '--frozen' in result['commands'][0]
PY

# Notice production reuses full source/supplement verification without executing
# Cargo or changing an existing compilation receipt. Preserve CRLF attribution.
NOTICES_RESULT="$TMP/android/app/build/outputs/papercusp-rust-notices-result.json"
NOTICES="$TMP/android/app/build/outputs/papercusp-rust-notices.json"
cp "$BUILD_RESULT" "$TMP/bin/build-receipt-before-notices.json"
cat >"$TMP/bin/cargo" <<'SH'
#!/usr/bin/env bash
echo 'Notice-only mode must not execute Cargo' >&2
exit 93
SH
chmod +x "$TMP/bin/cargo"
PATH="$TMP/bin:$PATH" run_helper source-notices >/dev/null
cmp "$BUILD_RESULT" "$TMP/bin/build-receipt-before-notices.json" || fail 'notices changed compilation receipt'
rm "$TMP/bin/cargo"
python3 - "$NOTICES_RESULT" "$NOTICES" <<'PY'
import hashlib,json,sys
receipt=json.load(open(sys.argv[1]));data=json.load(open(sys.argv[2]))
assert receipt['exitCode']==0 and receipt['verifiedRegistryPackages']==1 and receipt['verifiedVendorFiles']==6
assert receipt['noticeMetadata']['sha256']==hashlib.sha256(open(sys.argv[2],'rb').read()).hexdigest()
assert data['libraries'][0]['uniqueId']=='rust:source_proof_dependency:1.0.0'
assert len(data['libraries'][0]['licenses'])==4
assert any(license['content']=='Fixture permission text\r\nCopyright fixture author\r\n' for license in data['licenses'].values())
assert any('additional attribution' in license['content'] for license in data['licenses'].values())
assert any('Plural notices' in license['content'] for license in data['licenses'].values())
assert any('revision-pinned supplemental notice' in license['content'] for license in data['licenses'].values())
PY
for defect in omitted-authors omitted-plural changed-notice-digest declaration-mismatch empty-notice escaped-license-file bad-supplement wrong-vcs-revision changed-supplement; do
    cp "$TMP/bin/dependencies-backup.tar.gz" "$DEPENDENCIES"
    python3 - "$DEPENDENCIES" "$defect" <<'PY'
import hashlib,io,json,sys,tarfile
path,defect=sys.argv[1:]
with tarfile.open(path,'r:gz') as archive:
    rows={entry.name:archive.extractfile(entry).read() for entry in archive}
base='papercusp-mobile-source/android/app/build/outputs/papercusp-rust-dependencies'
package=base+'/source_proof_dependency-1.0.0/'
inventory=json.loads(rows[base+'-provenance.json']);record=inventory['packages'][0]
if defect=='omitted-authors':record['noticeFiles']=[x for x in record['noticeFiles'] if not x['path'].endswith('/AUTHORS')]
if defect=='omitted-plural':record['noticeFiles']=[x for x in record['noticeFiles'] if not x['path'].endswith('/NOTICES.md')]
if defect=='changed-notice-digest':record['noticeFiles'][0]['sha256']='0'*64
if defect=='declaration-mismatch':record['declaredLicense']='Apache-2.0'
if defect=='bad-supplement':record['licenseSupplement']={'path':'../outside','source':'https://example.invalid','sha256':'0'*64}
if defect=='wrong-vcs-revision':
    record['licenseSupplement']['sourceRevision']='ef'*20
    record['licenseSupplement']['source']='https://example.invalid/'+'ef'*20+'/LICENSE'
if defect=='changed-supplement':
    rows['papercusp-mobile-source/android/app/build/outputs/papercusp-rust-license-supplements/fixture.txt']=b'changed supplement\n'
if defect=='empty-notice':
    rows[package+'AUTHORS']=b' \n';record['noticeFiles'][0]['sha256']=hashlib.sha256(b' \n').hexdigest()
if defect=='escaped-license-file':
    rows[package+'Cargo.toml']+=b'license-file="../outside"\n';record['declaredLicenseFile']='../outside'
if defect in ('empty-notice','escaped-license-file'):
    checksum=json.loads(rows[package+'.cargo-checksum.json'])
    for name in checksum['files']:checksum['files'][name]=hashlib.sha256(rows[package+name]).hexdigest()
    rows[package+'.cargo-checksum.json']=json.dumps(checksum).encode()
rows[base+'-provenance.json']=json.dumps(inventory).encode()
with tarfile.open(path,'w:gz') as archive:
    for name,data in rows.items():
        entry=tarfile.TarInfo(name);entry.size=len(data);archive.addfile(entry,io.BytesIO(data))
PY
    if run_helper source-notices >"$TMP/bin/source-notices-$defect.log" 2>&1; then
        fail "source notices accepted $defect"
    fi
    [[ ! -f "$NOTICES_RESULT" && ! -f "$NOTICES" ]] || fail "$defect retained stale notice output"
done
cp "$TMP/bin/dependencies-backup.tar.gz" "$DEPENDENCIES"
run_helper source-notices >/dev/null
echo 'Exported Rust notices PASS: byte-preserved LICENSE/AUTHORS/NOTICES and pinned supplement; nine rejecting controls; no compilation'

for defect in stale-lock changed-file extra-file overlay-root escaping-path duplicate-entry redirected-config; do
    cp "$TMP/bin/dependencies-backup.tar.gz" "$DEPENDENCIES"
    python3 - "$DEPENDENCIES" "$defect" <<'PY'
import io,json,sys,tarfile
path,defect=sys.argv[1:]
with tarfile.open(path,'r:gz') as archive:
    rows=[(entry,archive.extractfile(entry).read()) for entry in archive]
vendor='papercusp-mobile-source/android/app/build/outputs/papercusp-rust-dependencies'
changed=[]
for entry,data in rows:
    if defect=='stale-lock' and entry.name.endswith('-provenance.json'):
        record=json.loads(data); record['cargoLockSha256']='0'*64; data=json.dumps(record).encode()
    if defect=='changed-file' and entry.name.endswith('/src/lib.rs'):data=b'pub fn value() -> u32 { 99 }\n'
    if defect=='redirected-config' and entry.name.endswith('.cargo/config.toml'):data=b'[source.crates-io]\nreplace-with="outside"\n'
    entry.size=len(data);changed.append((entry,data))
if defect in ('extra-file','overlay-root','escaping-path'):
    name={'extra-file':vendor+'/source_proof_dependency-1.0.0/extra.txt',
          'overlay-root':'papercusp-mobile-source/Cargo.toml',
          'escaping-path':'papercusp-mobile-source/../../escape.txt'}[defect]
    entry=tarfile.TarInfo(name);entry.size=5;changed.append((entry,b'extra'))
if defect=='duplicate-entry':changed.append(changed[0])
with tarfile.open(path,'w:gz') as archive:
    for entry,data in changed:archive.addfile(entry,io.BytesIO(data))
PY
    if run_helper source-verify-build host >"$TMP/bin/source-build-$defect.log" 2>&1; then
        fail "source build accepted $defect dependency supplement"
    fi
    [[ ! -f "$BUILD_RESULT" ]] || fail "$defect left a stale successful build receipt"
done
cp "$TMP/bin/dependencies-backup.tar.gz" "$DEPENDENCIES"

# A compiler failure must retain a failed receipt and its unique log.
printf 'this does not compile\n' >"$TMP/src/lib.rs"
git -C "$TMP" add src/lib.rs
git -C "$TMP" commit -qm broken-source-build-fixture
run_helper source-archive >/dev/null
if run_helper source-verify-build host >"$TMP/bin/source-build-compiler-error.log" 2>&1; then
    fail 'source compilation accepted invalid Rust'
fi
python3 - "$TMP" "$BUILD_RESULT" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]);result=json.load(open(sys.argv[2]))
assert result['exitCode']!=0 and not result['compiledArtifacts']
assert 'error:' in (root/result['log']['path']).read_text()
PY
printf '#[no_mangle]\npub extern "C" fn delivered_value() -> u32 { source_proof_dependency::value() }\n' >"$TMP/src/lib.rs"
git -C "$TMP" add src/lib.rs
git -C "$TMP" commit -qm restore-source-build-fixture
run_helper write 0.0.17 "$APK" "$AAB" >/dev/null
run_helper source-verify-build host >/dev/null
echo 'Offline exported-source compilation PASS: real locked dependency and eight rejecting controls'

# These controlled native/Gradle executors test archive orchestration and output
# guards, not Android compilation. The operational full-app run is separate.
mkdir -p "$TMP/tools/build-scripts" "$TMP/android/app" "$TMP/bin/sdk/platforms/android-36" \
    "$TMP/bin/sdk/ndk/27.0.12077973" "$TMP/bin/gradle-cache/caches"
cp "$ROOT/tools/build-scripts/resolve-java-home.sh" "$TMP/tools/build-scripts/"
cat >"$TMP/tools/build-scripts/verify-android-uniffi-abi.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 5 ]]
for path in "$@"; do [[ -s "$path" ]]; done
SH
printf 'Pkg.Revision=36\n' >"$TMP/bin/sdk/platforms/android-36/source.properties"
printf 'Pkg.Revision=27.0.12077973\n' >"$TMP/bin/sdk/ndk/27.0.12077973/source.properties"
printf 'ORG_GRADLE_PROJECT_fixtureSecret=must-not-load\n' >"$TMP/bin/gradle-cache/gradle.properties"
cat >"$TMP/bin/google-services.json" <<'JSON'
{"client":[{"client_info":{"android_client_info":{"package_name":"com.papercuspai.operator.mobile"}}}]}
JSON
cp "$TMP/bin/google-services.json" "$TMP/bin/google-services-backup.json"
cat >"$TMP/android/gradlew" <<'PY'
#!/usr/bin/env python3
import hashlib,json,os
from pathlib import Path
import sys,zipfile
assert '--offline' in sys.argv and '-x' in sys.argv
assert ':app:papercupSourceBuildInputs' in sys.argv
assert ':app:generateUniFfiKotlin' in sys.argv
project=Path(sys.argv[sys.argv.index('-p')+1])
# Real Gradle resolves this relative option under -p, not the caller's cwd.
assert (project/sys.argv[sys.argv.index('--init-script')+1]).is_file()
home=Path(os.environ['GRADLE_USER_HOME'])
assert not (home/'gradle.properties').exists() and not (home/'init.d').exists()
assert not any(key.startswith('ORG_GRADLE_PROJECT_') for key in os.environ)
assert 'PICOVOICE_ACCESS_KEY' not in os.environ
defect=os.environ.get('SOURCE_BUILD_FIXTURE_DEFECT')
if defect=='gradle-error':sys.exit(23)
build=Path('android/app/build');output=build/'outputs/apk/debug/app-debug.apk'
build.mkdir(parents=True,exist_ok=True)
record=[] if defect=='empty-resolution' else [{'configuration':'debugRuntimeClasspath','module':'fixture:source:1',
    'file':'source.txt','sha256':hashlib.sha256(Path('source.txt').read_bytes()).hexdigest(),'size':7}]
(build/'source-build-inputs.json').write_text(json.dumps(record))
if ':app:assembleDebug' not in sys.argv:sys.exit(0)
output.parent.mkdir(parents=True)
with zipfile.ZipFile(output,'w') as archive:
    archive.writestr('AndroidManifest.xml','fixture manifest')
    if defect!='missing-dex':archive.writestr('classes.dex','fixture dex')
    for abi in ('arm64-v8a','armeabi-v7a','x86','x86_64'):
        native=Path('android/app/src/main/jniLibs')/abi/'libpapercup.so'
        stripped=build/'intermediates/stripped_native_libs/debug/stripDebugDebugSymbols/out/lib'/abi/'libpapercup.so'
        stripped.parent.mkdir(parents=True);stripped.write_bytes(native.read_bytes())
        if defect=='missing-abi' and abi=='x86':continue
        archive.writestr('lib/'+abi+'/libpapercup.so',b'bad' if defect=='native-mismatch' else native.read_bytes())
if defect=='missing-apk':output.unlink()
if defect=='changed-config':
    with open(os.environ['PAPERCUP_SOURCE_GOOGLE_SERVICES'],'a') as stream:stream.write(' ')
PY
chmod +x "$TMP/android/gradlew"
git -C "$TMP" add android/gradlew tools/build-scripts/resolve-java-home.sh tools/build-scripts/verify-android-uniffi-abi.sh
git -C "$TMP" commit -qm exported-apk-orchestration-fixture
run_helper write 0.0.17 "$APK" "$AAB" >/dev/null
REAL_CARGO="$(command -v cargo)"
cat >"$TMP/bin/cargo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == ndk ]]; then
    "$SOURCE_BUILD_FIXTURE_CARGO" build --frozen --release --lib
    for row in arm64-v8a:aarch64-linux-android armeabi-v7a:armv7-linux-androideabi x86:i686-linux-android x86_64:x86_64-linux-android; do
        abi="${row%%:*}"; target="${row#*:}"
        mkdir -p "$CARGO_TARGET_DIR/$target/release" "android/app/src/main/jniLibs/$abi"
        cp "$CARGO_TARGET_DIR/release/libpapercup.so" "$CARGO_TARGET_DIR/$target/release/"
        cp "$CARGO_TARGET_DIR/release/libpapercup.so" "android/app/src/main/jniLibs/$abi/"
    done
elif [[ "$1" == run ]]; then
    mkdir -p android/app/src/main/kotlin/uniffi/papercup
    printf '// generated fixture binding\n' >android/app/src/main/kotlin/uniffi/papercup/papercup.kt
else
    exec "$SOURCE_BUILD_FIXTURE_CARGO" "$@"
fi
SH
chmod +x "$TMP/bin/cargo"
run_apk_fixture() {
    PATH="$TMP/bin:$PATH" SOURCE_BUILD_FIXTURE_CARGO="$REAL_CARGO" \
        ANDROID_SDK_ROOT="$TMP/bin/sdk" ANDROID_NDK_HOME="$TMP/bin/sdk/ndk/27.0.12077973" \
        GRADLE_USER_HOME="$TMP/bin/gradle-cache" \
        PAPERCUP_SOURCE_GOOGLE_SERVICES="${FIXTURE_GOOGLE_CONFIG-$TMP/bin/google-services.json}" \
        ORG_GRADLE_PROJECT_fixtureSecret=must-not-load PICOVOICE_ACCESS_KEY=must-not-load \
        run_helper source-verify-build android-apk
}
run_apk_fixture >"$TMP/bin/source-apk-pass.json"
python3 - "$TMP" "$BUILD_RESULT" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]);result=json.load(open(sys.argv[2]))
assert result['exitCode']==0 and result['mode']=='android-apk'
assert len(result['compiledArtifacts'])==5 and len(result['commands'])==5
assert ':app:assembleDebug' not in result['commands'][0] and result['commands'][1][1]=='ndk'
assert not any(argument.startswith(str(root)) for command in result['commands'] for argument in command)
apk=result['compiledArtifacts'][-1];path=root/apk['path']
assert path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest()==apk['sha256']
assert result['externalInputs']['googleServices']['sha256']==hashlib.sha256((root/'bin/google-services.json').read_bytes()).hexdigest()
assert len(result['externalInputs']['packagedRustLibraries'])==4
assert result['externalInputs']['environment']['personalGradleConfigLoaded'] is False
assert len(result['resolvedGradleArtifacts'])==1
PY
for defect in gradle-error missing-apk missing-dex missing-abi native-mismatch empty-resolution changed-config; do
    cp "$TMP/bin/google-services-backup.json" "$TMP/bin/google-services.json"
    if SOURCE_BUILD_FIXTURE_DEFECT="$defect" run_apk_fixture >"$TMP/bin/source-apk-$defect.log" 2>&1; then
        fail "exported APK accepted $defect"
    fi
    if [[ "$defect" == gradle-error ]]; then
        python3 - "$BUILD_RESULT" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]));assert result['exitCode']==23 and not result['compiledArtifacts']
PY
    else
        [[ ! -f "$BUILD_RESULT" ]] || fail "$defect left a stale APK success receipt"
    fi
done
cp "$TMP/bin/google-services-backup.json" "$TMP/bin/google-services.json"
if FIXTURE_GOOGLE_CONFIG='' run_apk_fixture >"$TMP/bin/source-apk-no-config.log" 2>&1; then
    fail 'exported APK accepted absent external config'
fi
printf '{"client":[]}\n' >"$TMP/bin/google-services.json"
if run_apk_fixture >"$TMP/bin/source-apk-wrong-package.log" 2>&1; then
    fail 'exported APK accepted wrong Firebase package'
fi
cp "$TMP/bin/google-services-backup.json" "$TMP/bin/google-services.json"
mv "$TMP/bin/sdk/platforms/android-36/source.properties" "$TMP/bin/sdk/platforms/android-36/source.properties.saved"
if run_apk_fixture >"$TMP/bin/source-apk-no-sdk.log" 2>&1; then
    fail 'exported APK accepted absent API 36 SDK'
fi
mv "$TMP/bin/sdk/platforms/android-36/source.properties.saved" "$TMP/bin/sdk/platforms/android-36/source.properties"
# Reintroduce the measured production defect in a private helper copy. The
# project-relative fixture must reject it before any expensive Cargo build.
cp "$HELPER" "$TMP/bin/legacy-init-provenance.sh"
python3 - "$TMP/bin/legacy-init-provenance.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);source=p.read_text()
old="(extracted / 'android/source-build-inputs.gradle').write_text"
assert source.count(old)==1
p.write_text(source.replace(old,"(extracted / 'source-build-inputs.gradle').write_text"))
PY
CORRECT_HELPER="$HELPER"
HELPER="$TMP/bin/legacy-init-provenance.sh"
if run_apk_fixture >"$TMP/bin/source-apk-legacy-init.log" 2>&1; then
    fail 'exported APK accepted the original misplaced init-script defect'
fi
python3 - "$TMP" "$BUILD_RESULT" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]);result=json.load(open(sys.argv[2]));log=(root/result['log']['path']).read_text()
assert result['exitCode']!=0 and not result['compiledArtifacts']
assert 'AssertionError' in log and 'Compiling ' not in log
PY
HELPER="$CORRECT_HELPER"
run_apk_fixture >/dev/null
echo 'Exported APK orchestration PASS: retained output/config hashes, isolated personal config, ten rejecting controls and original init-path mutant caught before compilation (fixture, not Android compilation)'

printf 'tamper' >>"$APK"
if run_helper verify 0.0.17 >/dev/null 2>&1; then
    echo "FAIL: tampered APK passed provenance verification" >&2
    exit 1
fi
truncate -s 2048 "$APK"
printf 'apk' | dd of="$APK" conv=notrunc status=none

if FAKE_APK_VERSION=9.9.9 run_helper write 0.0.17 "$APK" "$AAB" >/dev/null 2>&1; then
    echo "FAIL: APK version mismatch produced provenance" >&2
    exit 1
fi

if FAKE_APK_VERSION_CODE=16 run_helper write 0.0.17 "$APK" "$AAB" >/dev/null 2>&1; then
    echo "FAIL: APK versionCode mismatch produced provenance" >&2
    exit 1
fi

printf 'dirty\n' >>"$TMP/source.txt"
if run_helper write 0.0.17 "$APK" "$AAB" >/dev/null 2>&1; then
    echo "FAIL: dirty source produced provenance" >&2
    exit 1
fi

echo "✓ Android release provenance rejects version, source and hash drift; source archive includes pinned nested submodules and excludes local credentials"

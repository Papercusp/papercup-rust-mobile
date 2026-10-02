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

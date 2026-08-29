#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/tools/build-scripts/android-release-provenance.sh"
GRADLE="$ROOT/android/app/build.gradle.kts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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
git -C "$TMP" add .gitignore source.txt
git -C "$TMP" commit -qm initial

APK="$TMP/android/app/build/outputs/apk/release/app-release.apk"
AAB="$TMP/android/app/build/outputs/bundle/release/app-release.aab"
mkdir -p "$(dirname "$APK")" "$(dirname "$AAB")" "$TMP/bin"
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
NODE

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

echo "✓ Android release provenance producer rejects version, source, and hash drift, and generates the candidate record without invalidating provenance"

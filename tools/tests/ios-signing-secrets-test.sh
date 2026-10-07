#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Loading the TestFlight signing secrets (WI-10006899): run the real
# ios-signing-secrets.sh against fixture Apple files and a fake `gh`, never real
# credentials or a real repository. The subject path is overridable so a mutated
# COPY can be checked without touching the tree.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECRETS="${PAPERCUP_TEST_SECRETS_SCRIPT:-$ROOT/tools/build-scripts/ios-signing-secrets.sh}"
SIGNING="${PAPERCUP_TEST_SIGNING_SCRIPT:-$ROOT/tools/build-scripts/ios-ci-signing.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TEAM=ABCDE12345
BUNDLE=com.papercuspai.operator.mobile
KEY_ID=FIXTURE001
ISSUER=69a6de7f-1111-2222-3333-444455556666
F="$TMP/apple"
STORE="$TMP/gh-store"
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/src"

fail() {
    echo "FAIL: $*" >&2
    [ -f "$TMP/err" ] && sed 's/^/  stderr: /' "$TMP/err" >&2
    exit 1
}

# ------------------------------------------------------------------- fake gh
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
    "secret set")
        name="$3"; shift 3
        cat > "$FAKE_GH_STORE/$name"
        echo "$name $*" >> "$FAKE_GH_STORE/set.log" ;;
    "secret list")
        for path in "$FAKE_GH_STORE"/*; do
            name="$(basename "$path")"
            [ "$name" = set.log ] && continue
            printf '%s\t%s\n' "$name" "${FAKE_GH_UPDATED:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
        done ;;
    *) echo "fake gh: unexpected $*" >&2; exit 2 ;;
esac
GH
chmod +x "$TMP/bin/gh"

# ------------------------------------------------------------ fixture files
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/src/dist.key" 2>/dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/src/other.key" 2>/dev/null
make_cert() { # <kind> <key> <out.cer>
    openssl req -x509 -new -key "$2" -days 2 -outform der -out "$3" \
        -subj "/UID=$BUNDLE/CN=$1: Papercusp Fixture ($TEAM)/OU=$TEAM/O=Papercusp Fixture/C=US" 2>/dev/null
}
make_cert 'Apple Distribution' "$TMP/src/dist.key" "$TMP/src/distribution.cer"
make_cert 'Apple Development' "$TMP/src/dist.key" "$TMP/src/development.cer"
make_cert 'Apple Distribution' "$TMP/src/other.key" "$TMP/src/foreign.cer"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/src/signer.key" -out "$TMP/src/signer.pem" \
    -subj '/CN=Papercup profile fixture' -days 2 >/dev/null 2>&1
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$TMP/src/AuthKey_$KEY_ID.p8" 2>/dev/null

make_profile() { # <name> <cert.cer carried> <team>
    python3 - "$2" "$TMP/src/$1.plist" "$3" "$BUNDLE" <<'PY'
import datetime
import plistlib
import sys

cert_path, out, team, bundle = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None, microsecond=0)
with open(out, "wb") as handle:
    plistlib.dump({
        "Name": "Papercusp App Store",
        "UUID": "11111111-2222-3333-4444-555555555555",
        "TeamIdentifier": [team],
        "ExpirationDate": now + datetime.timedelta(days=300),
        "DeveloperCertificates": [open(cert_path, "rb").read()],
        "Entitlements": {
            "application-identifier": f"{team}.{bundle}",
            "get-task-allow": False,
            "aps-environment": "production",
        },
    }, handle)
PY
    openssl smime -sign -binary -nodetach -outform der -signer "$TMP/src/signer.pem" \
        -inkey "$TMP/src/signer.key" -in "$TMP/src/$1.plist" -out "$TMP/src/$1.mobileprovision"
}
make_profile good "$TMP/src/distribution.cer" "$TEAM"
make_profile foreign "$TMP/src/foreign.cer" "$TEAM"
make_profile wrong-team "$TMP/src/distribution.cer" ZZZZZ99999

# A complete folder as the owner would leave it; tests then break one thing.
make_folder() {
    rm -rf "$F" "$STORE"
    mkdir -p "$F/asc" "$F/apns" "$STORE"
    chmod 700 "$F"
    cp "$TMP/src/dist.key" "$F/dist.key"
    chmod 600 "$F/dist.key"
    cp "$TMP/src/distribution.cer" "$F/distribution.cer"
    cp "$TMP/src/good.mobileprovision" "$F/Papercusp_App_Store.mobileprovision"
    cp "$TMP/src/AuthKey_$KEY_ID.p8" "$F/asc/AuthKey_$KEY_ID.p8"
    chmod 644 "$F/asc/AuthKey_$KEY_ID.p8" # browser downloads arrive world-readable
    printf 'Team ID: %s\nASC key ID: %s\nAPNs key ID: APNSKEY001\nIssuer ID: %s\n' \
        "$TEAM" "$KEY_ID" "$ISSUER" > "$F/notes.txt"
}

run_secrets() {
    env PATH="$TMP/bin:$PATH" HOME="$TMP/home" PAPERCUP_APPLE_SECRETS_DIR="$F" \
        PAPERCUP_IOS_SIGNING_CONFIG="$TMP/native-signing.json" PAPERCUP_SIGNING_SCRIPT="$SIGNING" FAKE_GH_STORE="$STORE" \
        "$@" > "$TMP/out" 2> "$TMP/err"
}
secrets() { run_secrets bash "$SECRETS" "$@"; }

expect_refused() { # <label> <stderr pattern> [mode]
    if secrets "${3:-plan}"; then fail "$1: accepted"; fi
    grep -q -- "$2" "$TMP/err" || fail "$1: refusal does not say '$2'"
    echo "ok: refuses $1"
}

# ------------------------------------------------------------- waiting state
make_folder
rm -f "$F"/*.cer "$F"/*.mobileprovision "$F"/asc/*.p8 "$F/notes.txt"
expect_refused 'a folder with only dist.key' 'are not all in'
for missing in 'Apple Distribution certificate' 'App Store provisioning profile' \
    'App Store Connect API key' 'identifiers'; do
    grep -q "WAITING_FOR: $missing" "$TMP/err" || fail "the waiting refusal does not name '$missing'"
done

# --------------------------------------------------------------- plan (dry)
make_folder
secrets plan || fail "plan rejected a complete folder"
for name in APPLE_TEAM_ID IOS_DIST_CERT_P12_BASE64 IOS_DIST_CERT_PASSWORD IOS_APPSTORE_PROFILE_BASE64 \
    ASC_API_KEY_ID ASC_API_ISSUER_ID ASC_API_KEY_P8_BASE64; do
    grep -q "^SECRET: $name " "$TMP/out" || fail "plan does not list $name"
done
[ "$(grep -c '^SECRET: ' "$TMP/out")" -eq 7 ] || fail "plan lists other than 7 secrets"
[ ! -s "$STORE/set.log" ] || fail "plan called gh secret set"
password="$(tr -d '\n' < "$F/dist.p12.password")"
[ -n "$password" ] || fail "no p12 password was written"
for leak in "$password" "$(base64 -w0 < "$F/dist.p12" | cut -c1-40)" \
    "$(base64 -w0 < "$F/asc/AuthKey_$KEY_ID.p8" | cut -c1-40)" "$(sed -n 2p "$F/asc/AuthKey_$KEY_ID.p8")"; do
    if grep -qF -- "$leak" "$TMP/out" "$TMP/err"; then fail "plan output contains a secret value"; fi
done
[ "$(stat -c '%a' "$F/dist.p12")" = 600 ] || fail "dist.p12 is not mode 600"
[ "$(stat -c '%a' "$F/dist.p12.password")" = 600 ] || fail "dist.p12.password is not mode 600"
echo "ok: plan validates, lists 7 secrets, sets nothing and prints no value"

# ------------------------------------------------------------------- apply
secrets apply || fail "apply failed on a complete folder"
grep -q '^APPLIED: 7 ' "$TMP/out" || fail "apply did not report success"
[ ! -s "$STORE/set.log" ] || fail 'apply published to GitHub'
[ "$(stat -c '%a' "$TMP/native-signing.json")" = 600 ] || fail 'native JSON is not owner-only'
python3 - "$TMP/native-signing.json" "$STORE" <<'PY'
import json
import sys
from pathlib import Path
values = json.loads(Path(sys.argv[1]).read_text())
assert len(values) == 7
for key, value in values.items():
    (Path(sys.argv[2]) / key).write_text(value)
PY
[ "$(cat "$STORE/APPLE_TEAM_ID")" = "$TEAM" ] || fail 'native JSON team differs'
[ "$(cat "$STORE/ASC_API_KEY_ID")" = "$KEY_ID" ] || fail 'native JSON key ID differs'
[ "$(cat "$STORE/ASC_API_ISSUER_ID")" = "$ISSUER" ] || fail 'native JSON issuer differs'
base64 -d < "$STORE/IOS_APPSTORE_PROFILE_BASE64" | cmp -s - "$F/Papercusp_App_Store.mobileprovision" \
    || fail "IOS_APPSTORE_PROFILE_BASE64 is not the profile"
base64 -d < "$STORE/ASC_API_KEY_P8_BASE64" | cmp -s - "$F/asc/AuthKey_$KEY_ID.p8" \
    || fail "ASC_API_KEY_P8_BASE64 is not the API key"
base64 -d < "$STORE/IOS_DIST_CERT_P12_BASE64" > "$TMP/set.p12"
openssl pkcs12 -in "$TMP/set.p12" -passin "file:$STORE/IOS_DIST_CERT_PASSWORD" -nocerts -nodes 2>/dev/null \
    | openssl pkey -pubout > "$TMP/p12.pub" || fail "the p12 secret does not open with the password secret"
openssl pkey -in "$F/dist.key" -pubout | cmp -s - "$TMP/p12.pub" || fail "the p12 secret holds a different key"
echo "ok: apply sets 7 secrets whose values are the folder's files and identifiers"

secrets apply || fail "a second apply failed"
grep -q 'dist.p12 (reused)' "$TMP/out" || fail "a second run rebuilt the p12"
[ "$(tr -d '\n' < "$F/dist.p12.password")" = "$password" ] || fail "a second run changed the p12 password"
echo "ok: re-running reuses the p12 and its password"

make_folder
chmod 644 "$TMP/native-signing.json"
if secrets apply; then fail 'apply overwrote a publicly readable native config'; fi
grep -q 'owner-only' "$TMP/err" || fail 'public config refusal did not name its mode'
rm "$TMP/native-signing.json"
echo 'ok: private config readback and refusal guards'

# ---------------------------------------------------------------- refusals
make_folder; cp "$TMP/src/other.key" "$F/dist.key"
expect_refused 'a certificate not issued for dist.key' KEY_MISMATCH
make_folder; rm "$F/distribution.cer"; cp "$TMP/src/development.cer" "$F/development.cer"
expect_refused 'an Apple Development certificate' CERT_REJECTED
make_folder; cp "$TMP/src/foreign.mobileprovision" "$F/Papercusp_App_Store.mobileprovision"
expect_refused 'a profile without this certificate' 'does not include certificate'
make_folder; cp "$TMP/src/wrong-team.mobileprovision" "$F/Papercusp_App_Store.mobileprovision"
expect_refused "a profile for another team (CI's check-profile)" 'PROFILE_REJECTED: profile team'
make_folder; echo 'old issuer 00000000-aaaa-bbbb-cccc-000000000000' >> "$F/notes.txt"
expect_refused 'notes with two UUIDs' 'more than one UUID'
make_folder; sed -i '/Issuer/d' "$F/notes.txt"
expect_refused 'notes without an Issuer ID' 'no Issuer ID'
make_folder; cp "$TMP/src/foreign.cer" "$F/second.cer"
expect_refused 'two certificates' 'AMBIGUOUS: Apple Distribution certificate'
make_folder; chmod 750 "$F"
expect_refused 'a folder readable by its group' 'readable by group or others'
make_folder; mv "$F/asc/AuthKey_$KEY_ID.p8" "$F/asc/AuthKey_bad.p8"
expect_refused 'an API key file name without a key ID' 'must be 10 characters'

echo "PASS: ios-signing-secrets"

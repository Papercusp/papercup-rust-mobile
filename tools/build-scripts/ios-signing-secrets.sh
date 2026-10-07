#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Load Apple signing material into owner-only native signing JSON.
#
# The owner downloads the Apple files into a private folder outside every repo
# (default ~/.papercusp/secrets/apple, see docs/BUILD.md "TestFlight"):
#   dist.key              distribution private key (generated with dist.csr)
#   <any>.cer             the Apple Distribution certificate issued for dist.csr
#   <any>.mobileprovision the App Store profile for com.papercuspai.operator.mobile
#   asc/AuthKey_<ID>.p8   the App Store Connect API team key
#   notes.txt             identifiers; the only UUID in it is the API Issuer ID
#
# `plan` (the default) validates everything and lists the secrets it would set.
# `apply` writes the verified native JSON outside the repository. Neither
# prints a secret value. The certificate's key, team and type are checked here,
# and the profile goes through the same check-profile the CI job runs, so a
# wrong file fails on this machine instead of on a paid macOS runner.
#
# Usage: ios-signing-secrets.sh [plan|apply]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIGNING="${PAPERCUP_SIGNING_SCRIPT:-$ROOT/tools/build-scripts/ios-ci-signing.sh}"
DIR="${PAPERCUP_APPLE_SECRETS_DIR:-$HOME/.papercusp/secrets/apple}"
OUTPUT="${PAPERCUP_IOS_SIGNING_CONFIG:-$HOME/.config/papercusp/ios-signing.json}"
MODE="${1:-plan}"
SECRET_NAMES="APPLE_TEAM_ID IOS_DIST_CERT_P12_BASE64 IOS_DIST_CERT_PASSWORD IOS_APPSTORE_PROFILE_BASE64 ASC_API_KEY_ID ASC_API_ISSUER_ID ASC_API_KEY_P8_BASE64"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

case "$MODE" in
    plan | apply) ;;
    *) die "usage: ios-signing-secrets.sh [plan|apply]" ;;
esac

umask 077
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Exactly one file matching <dir>/<glob>, or a named refusal ("waiting for" when none).
one_file() {
    local label="$1" dir="$2" glob="$3" matches=()
    shopt -s nullglob
    # shellcheck disable=SC2206 # the unquoted glob expansion is the point
    matches=("$dir"/$glob)
    shopt -u nullglob
    if [ "${#matches[@]}" -eq 0 ]; then
        echo "WAITING_FOR: $label ($dir/$glob)" >&2
        return 1
    fi
    if [ "${#matches[@]}" -gt 1 ]; then
        echo "AMBIGUOUS: $label has ${#matches[@]} candidates: ${matches[*]}" >&2
        return 1
    fi
    printf '%s\n' "${matches[0]}"
}

private_mode() {
    local mode
    mode="$(python3 - "$1" <<'PY'
import os
import sys
print(format(os.stat(sys.argv[1]).st_mode & 0o777, 'o'))
PY
)"
    [ $((8#$mode & 8#077)) -eq 0 ] || die "$1 is readable by group or others (mode $mode); chmod go-rwx it"
}

# ------------------------------------------------------------------ the folder
[ -d "$DIR" ] || die "secrets folder not found: $DIR"
private_mode "$DIR"
[ -f "$DIR/dist.key" ] || die "distribution private key not found: $DIR/dist.key"
private_mode "$DIR/dist.key"

waiting=0
cer="$(one_file 'Apple Distribution certificate' "$DIR" '*.cer')" || waiting=1
profile="$(one_file 'App Store provisioning profile' "$DIR" '*.mobileprovision')" || waiting=1
p8="$(one_file 'App Store Connect API key' "$DIR/asc" 'AuthKey_*.p8')" || waiting=1
[ -f "$DIR/notes.txt" ] || { echo "WAITING_FOR: identifiers ($DIR/notes.txt)" >&2; waiting=1; }
[ "$waiting" -eq 0 ] || die "the Apple files are not all in $DIR yet"

# ----------------------------------------------------------------- certificate
if ! openssl x509 -inform der -in "$cer" -out "$WORK/dist.pem" 2>/dev/null \
    && ! openssl x509 -inform pem -in "$cer" -out "$WORK/dist.pem" 2>/dev/null; then
    die "$cer is not an X.509 certificate"
fi
subject="$(openssl x509 -in "$WORK/dist.pem" -noout -subject -nameopt RFC2253,sep_comma_plus)"
case "$subject" in
    *"CN=Apple Distribution: "* | *"CN=iPhone Distribution: "*) ;;
    *) echo "CERT_REJECTED: $subject" >&2
       die "$cer is not an Apple Distribution certificate (an Apple Development one cannot sign App Store builds)" ;;
esac
openssl x509 -in "$WORK/dist.pem" -noout -checkend 0 >/dev/null || die "$cer has expired"
team="$(printf '%s\n' "$subject" | tr ',' '\n' | sed -n 's/^OU=//p' | head -n 1)"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || die "could not read a 10-character team ID from the certificate subject"

openssl x509 -in "$WORK/dist.pem" -noout -pubkey > "$WORK/cert.pub"
openssl pkey -in "$DIR/dist.key" -pubout > "$WORK/key.pub" 2>/dev/null || die "$DIR/dist.key is not a private key"
if ! cmp -s "$WORK/cert.pub" "$WORK/key.pub"; then
    echo "KEY_MISMATCH: $cer was not issued for $DIR/dist.key" >&2
    die "upload dist.csr (made from dist.key) when creating the certificate"
fi
cert_sha1="$(openssl x509 -in "$WORK/dist.pem" -noout -fingerprint -sha1 | sed -e 's/^.*=//' -e 's/://g' | tr 'a-f' 'A-F')"

# --------------------------------------------------------------------- profile
profile_info="$(PAPERCUP_PROFILE_DECODER=openssl bash "$SIGNING" check-profile "$profile" "$team")"
profile_sha1s="$(printf '%s' "$profile_info" | cut -f3)"
case ",$profile_sha1s," in
    *",$cert_sha1,"*) ;;
    *) echo "PROFILE_REJECTED: $profile does not include certificate $cert_sha1" >&2
       die "regenerate the profile and select the new Apple Distribution certificate" ;;
esac

# --------------------------------------------------------- App Store Connect key
key_id="$(basename "$p8" .p8)"
key_id="${key_id#AuthKey_}"
[[ "$key_id" =~ ^[A-Z0-9]{10}$ ]] || die "$p8: the key ID in the file name must be 10 characters"
openssl pkey -in "$p8" -noout 2>/dev/null || die "$p8 is not a private key"

issuers="$(grep -oiE '\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b' "$DIR/notes.txt" | tr 'A-F' 'a-f' | sort -u || true)"
case "$(printf '%s' "$issuers" | grep -c . || true)" in
    1) issuer="$issuers" ;;
    0) die "notes.txt has no Issuer ID (the UUID shown above the App Store Connect API keys)" ;;
    *) die "notes.txt has more than one UUID; keep only the App Store Connect Issuer ID" ;;
esac

# ------------------------------------------------------------- PKCS#12 bundle
# SHA1-3DES encryption with a SHA1 MAC imports on every macOS keychain without
# OpenSSL's legacy provider. The bundle and its password stay in the private
# folder so re-running does not churn the secret.
p12="$DIR/dist.p12"
pass_file="$DIR/dist.p12.password"
p12_matches() {
    [ -s "$p12" ] && [ -s "$pass_file" ] || return 1
    openssl pkcs12 -in "$p12" -passin "file:$pass_file" -nokeys -clcerts 2>/dev/null \
        | openssl x509 -noout -pubkey 2>/dev/null | cmp -s - "$WORK/cert.pub"
}
if p12_matches; then
    p12_state=reused
else
    openssl rand -hex 24 > "$pass_file"
    openssl pkcs12 -export -inkey "$DIR/dist.key" -in "$WORK/dist.pem" -name "Apple Distribution ($team)" \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
        -passout "file:$pass_file" -out "$p12"
    p12_matches || die "the PKCS#12 bundle written to $p12 does not open with its password"
    p12_state=built
fi
private_mode "$p12"
private_mode "$pass_file"

# ---------------------------------------------------------------- the secrets
value_of() {
    case "$1" in
        APPLE_TEAM_ID) printf '%s' "$team" ;;
        IOS_DIST_CERT_P12_BASE64) base64 < "$p12" | tr -d '\n' ;;
        IOS_DIST_CERT_PASSWORD) tr -d '\n' < "$pass_file" ;;
        IOS_APPSTORE_PROFILE_BASE64) base64 < "$profile" | tr -d '\n' ;;
        ASC_API_KEY_ID) printf '%s' "$key_id" ;;
        ASC_API_ISSUER_ID) printf '%s' "$issuer" ;;
        ASC_API_KEY_P8_BASE64) base64 < "$p8" | tr -d '\n' ;;
    esac
}
source_of() {
    case "$1" in
        APPLE_TEAM_ID) echo "certificate subject OU" ;;
        IOS_DIST_CERT_P12_BASE64) echo "$p12 ($p12_state)" ;;
        IOS_DIST_CERT_PASSWORD) echo "$pass_file" ;;
        IOS_APPSTORE_PROFILE_BASE64) echo "$profile ($(printf '%s' "$profile_info" | cut -f1))" ;;
        ASC_API_KEY_ID) echo "$p8 file name" ;;
        ASC_API_ISSUER_ID) echo "$DIR/notes.txt" ;;
        ASC_API_KEY_P8_BASE64) echo "$p8" ;;
    esac
}

# The same fail-closed gate the workflow runs first must accept these values.
# They reach it through the environment (owner-only /proc/<pid>/environ), never
# through argv, which any local user can read with ps.
if ! (
    for name in $SECRET_NAMES; do
        export "$name=$(value_of "$name")"
    done
    exec bash "$SIGNING" require-secrets
) > "$WORK/gate.log" 2>&1; then
    cat "$WORK/gate.log" >&2
    die "the workflow's secrets gate rejects these values"
fi

for name in $SECRET_NAMES; do
    printf 'SECRET: %-28s <- %s (%s bytes)\n' "$name" "$(source_of "$name")" "$(value_of "$name" | wc -c)"
done

if [ "$MODE" = plan ]; then
    echo "PLAN: validated; run 'ios-signing-secrets.sh apply' to write owner-only native signing JSON"
    exit 0
fi

# The native runner consumes this private JSON; no external secret publication.
# Values enter Python through the environment, never argv or printed shell code.
(
    for name in $SECRET_NAMES; do
        export "$name=$(value_of "$name")"
    done
    python3 - "$OUTPUT" "$ROOT" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path
path, repo = (Path(value).resolve() for value in sys.argv[1:])
if path.is_relative_to(repo):
    raise SystemExit('ERROR: native signing config must be outside the repository')
if path.exists() and (not path.is_file() or path.stat().st_mode & 0o077):
    raise SystemExit('ERROR: existing native signing config must be owner-only')
path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
keys = ('APPLE_TEAM_ID', 'IOS_DIST_CERT_P12_BASE64', 'IOS_DIST_CERT_PASSWORD',
        'IOS_APPSTORE_PROFILE_BASE64', 'ASC_API_KEY_ID', 'ASC_API_ISSUER_ID', 'ASC_API_KEY_P8_BASE64')
values = {key: os.environ[key] for key in keys}
fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.ios-signing-')
try:
    with os.fdopen(fd, 'w') as stream:
        json.dump(values, stream)
    os.replace(temporary, path)
    if json.loads(path.read_text()) != values or path.stat().st_mode & 0o077:
        raise SystemExit('ERROR: native signing config readback failed')
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
)
echo "APPLIED: 7 TestFlight signing inputs written to owner-only native JSON"

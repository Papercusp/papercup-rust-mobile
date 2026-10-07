#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Apple signing setup for the native tools/ios-ci.py TestFlight route.
#
# Secrets arrive as injected environment variables on the native Mac. Signing material
# is written only under $PAPERCUP_SIGNING_DIR (default $TMPDIR), never into
# the repository, and `cleanup` removes it together with the temporary keychain.
#
# Usage: ios-ci-signing.sh require-secrets | install | cleanup
#        ios-ci-signing.sh check-profile <file.mobileprovision> <team-id>
set -euo pipefail

REQUIRED_SECRETS="APPLE_TEAM_ID IOS_DIST_CERT_P12_BASE64 IOS_DIST_CERT_PASSWORD IOS_APPSTORE_PROFILE_BASE64 ASC_API_KEY_ID ASC_API_ISSUER_ID ASC_API_KEY_P8_BASE64"
APP_BUNDLE_ID="${PAPERCUP_APP_BUNDLE_ID:-com.papercuspai.operator.mobile}"
WORK_DIR="${PAPERCUP_SIGNING_DIR:-${TMPDIR:-/tmp}/papercup-signing}"
KEYCHAIN="$WORK_DIR/papercup-ci.keychain-db"
WWDR_URL="https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer"
PROFILE_DIRS=(
    "$HOME/Library/MobileDevice/Provisioning Profiles"
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
)

die() {
    echo "ERROR: $*" >&2
    exit 1
}

is_macos() {
    [ "$(uname -s)" = Darwin ]
}

# Fail closed before any build: name every missing secret, then reject values
# that cannot possibly be right, so a typo surfaces here and not in xcodebuild.
require_secrets() {
    local name missing=0
    for name in $REQUIRED_SECRETS; do
        if [ -z "${!name:-}" ]; then
            echo "MISSING_SECRET: $name" >&2
            missing=$((missing + 1))
        fi
    done
    if [ "$missing" -gt 0 ]; then
        die "TestFlight signing needs $missing missing native signing input(s); see docs/BUILD.md (TestFlight)"
    fi
    if ! [[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
        echo "INVALID_SECRET: APPLE_TEAM_ID" >&2
        die "APPLE_TEAM_ID must be the 10-character Apple Developer team ID"
    fi
    for name in IOS_DIST_CERT_P12_BASE64 IOS_APPSTORE_PROFILE_BASE64 ASC_API_KEY_P8_BASE64; do
        if ! printf '%s' "${!name}" | base64 --decode >/dev/null 2>&1; then
            echo "INVALID_SECRET: $name" >&2
            die "$name must be the base64 encoding of the file"
        fi
    done
    echo "OK: all TestFlight signing secrets are present"
}

decode_profile() {
    if [ "${PAPERCUP_PROFILE_DECODER:-}" != openssl ] && is_macos; then
        security cms -D -i "$1"
    else
        openssl smime -inform der -verify -noverify -in "$1" 2>/dev/null
    fi
}

# Prints "<name>\t<uuid>\t<sha1 of each certificate, comma separated>" for an
# App Store distribution profile of this app and team; refuses anything else.
check_profile() {
    local profile="$1" team="$2" plist
    [ -f "$profile" ] || die "provisioning profile not found: $profile"
    plist="$(mktemp)"
    if ! decode_profile "$profile" > "$plist" || [ ! -s "$plist" ]; then
        rm -f "$plist"
        die "IOS_APPSTORE_PROFILE_BASE64 is not a signed provisioning profile"
    fi
    python3 - "$plist" "$team" "$APP_BUNDLE_ID" <<'PY' || { rm -f "$plist"; exit 1; }
import datetime
import hashlib
import plistlib
import sys

path, team, bundle_id = sys.argv[1:]
with open(path, "rb") as handle:
    profile = plistlib.load(handle)
entitlements = profile.get("Entitlements", {})
problems = []
if team not in profile.get("TeamIdentifier", []):
    problems.append(f"profile team {profile.get('TeamIdentifier')} is not {team}")
if entitlements.get("application-identifier") != f"{team}.{bundle_id}":
    problems.append(
        f"profile is for {entitlements.get('application-identifier')}, not {team}.{bundle_id}")
if "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices"):
    problems.append("profile lists devices; an App Store profile must not")
if entitlements.get("get-task-allow", False):
    problems.append("profile allows debugging (development profile); use App Store distribution")
if entitlements.get("aps-environment") != "production":
    problems.append("profile lacks production Push Notifications (aps-environment)")
expires = profile.get("ExpirationDate")
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
if expires is None or expires.replace(tzinfo=None) <= now:
    problems.append(f"profile expired at {expires}")
certs = profile.get("DeveloperCertificates", [])
if not certs:
    problems.append("profile carries no distribution certificate")
if problems:
    for problem in problems:
        print(f"PROFILE_REJECTED: {problem}", file=sys.stderr)
    sys.exit(1)
sha1s = ",".join(hashlib.sha1(cert).hexdigest().upper() for cert in certs)
print(f"{profile['Name']}\t{profile['UUID']}\t{sha1s}")
PY
    rm -f "$plist"
}

emit_env() {
    : "${PAPERCUP_SIGNING_ENV_FILE:?Native signing requires an owner-only temporary JSON environment file}"
    python3 - "$PAPERCUP_SIGNING_ENV_FILE" "$1" "$2" <<'PY'
import json
import os
import sys
from pathlib import Path
path, name, value = sys.argv[1:]
target = Path(path)
values = json.loads(target.read_text()) if target.exists() else {}
values[name] = value
old = os.umask(0o077)
try:
    target.write_text(json.dumps(values))
    target.chmod(0o600)
finally:
    os.umask(old)
PY
}

install_signing() {
    require_secrets
    is_macos || die "install needs macOS (security, codesign, xcodebuild)"
    local profile_info profile_name profile_uuid profile_sha1s keychain_password identity dir
    mkdir -p "$WORK_DIR"
    chmod 700 "$WORK_DIR"

    printf '%s' "$IOS_APPSTORE_PROFILE_BASE64" | base64 --decode > "$WORK_DIR/profile.mobileprovision"
    profile_info="$(check_profile "$WORK_DIR/profile.mobileprovision" "$APPLE_TEAM_ID")"
    IFS=$'\t' read -r profile_name profile_uuid profile_sha1s <<< "$profile_info"

    keychain_password="$(openssl rand -hex 24)"
    # Native logs have no Actions masking processor; never print this password.
    security create-keychain -p "$keychain_password" "$KEYCHAIN"
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "$keychain_password" "$KEYCHAIN"
    if curl -fsSL --retry 3 "$WWDR_URL" -o "$WORK_DIR/wwdr.cer"; then
        security import "$WORK_DIR/wwdr.cer" -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null || true
    else
        echo "WARN: could not fetch the Apple WWDR G3 intermediate; relying on the runner's copy" >&2
    fi
    printf '%s' "$IOS_DIST_CERT_P12_BASE64" | base64 --decode > "$WORK_DIR/dist.p12"
    security import "$WORK_DIR/dist.p12" -k "$KEYCHAIN" -f pkcs12 -P "$IOS_DIST_CERT_PASSWORD" \
        -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/xcodebuild >/dev/null
    rm -f "$WORK_DIR/dist.p12"
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
        -k "$keychain_password" "$KEYCHAIN" >/dev/null

    # Put the temporary keychain first while keeping the runner's own ones.
    local search_list=("$KEYCHAIN") line
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line#\"}"
        line="${line%\"}"
        [ -n "$line" ] && [ "$line" != "$KEYCHAIN" ] && search_list+=("$line")
    done < <(security list-keychains -d user)
    security list-keychains -d user -s "${search_list[@]}"

    identity="$(security find-identity -v -p codesigning "$KEYCHAIN" \
        | awk '/Apple Distribution/ { print $2; exit }')"
    [ -n "$identity" ] || die "IOS_DIST_CERT_P12_BASE64 holds no valid Apple Distribution identity"
    case ",$profile_sha1s," in
        *",$identity,"*) ;;
        *) die "the provisioning profile '$profile_name' does not include the imported distribution certificate $identity" ;;
    esac

    for dir in "${PROFILE_DIRS[@]}"; do
        mkdir -p "$dir"
        cp "$WORK_DIR/profile.mobileprovision" "$dir/$profile_uuid.mobileprovision"
    done
    printf '%s\n' "$profile_uuid" > "$WORK_DIR/profile.uuid"

    mkdir -p "$WORK_DIR/private_keys"
    printf '%s' "$ASC_API_KEY_P8_BASE64" | base64 --decode \
        > "$WORK_DIR/private_keys/AuthKey_${ASC_API_KEY_ID}.p8"
    chmod 600 "$WORK_DIR/private_keys/AuthKey_${ASC_API_KEY_ID}.p8"

    emit_env PAPERCUP_SIGNING_STYLE manual
    emit_env PAPERCUP_DEVELOPMENT_TEAM "$APPLE_TEAM_ID"
    emit_env PAPERCUP_PROVISIONING_PROFILE "$profile_name"
    emit_env PAPERCUP_CI_KEYCHAIN "$KEYCHAIN"
    emit_env APP_STORE_CONNECT_API_KEY_ID "$ASC_API_KEY_ID"
    emit_env APP_STORE_CONNECT_API_ISSUER_ID "$ASC_API_ISSUER_ID"
    emit_env APP_STORE_CONNECT_API_KEY_PATH "$WORK_DIR/private_keys/AuthKey_${ASC_API_KEY_ID}.p8"
    echo "OK: identity $identity and profile '$profile_name' ($profile_uuid) installed"
}

cleanup_signing() {
    local uuid dir
    if is_macos; then
        security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    fi
    if [ -f "$WORK_DIR/profile.uuid" ]; then
        uuid="$(cat "$WORK_DIR/profile.uuid")"
        for dir in "${PROFILE_DIRS[@]}"; do
            rm -f "$dir/$uuid.mobileprovision"
        done
    fi
    rm -rf "$WORK_DIR"
    echo "OK: temporary signing material removed"
}

case "${1:-}" in
    require-secrets) require_secrets ;;
    check-profile)
        [ "$#" -eq 3 ] || die "usage: ios-ci-signing.sh check-profile <file.mobileprovision> <team-id>"
        check_profile "$2" "$3"
        ;;
    install) install_signing ;;
    cleanup) cleanup_signing ;;
    *) die "usage: ios-ci-signing.sh require-secrets|install|cleanup|check-profile <file> <team>" ;;
esac

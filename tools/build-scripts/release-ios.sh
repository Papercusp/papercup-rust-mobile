#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Reproducible archive/export/upload entry point for the public iPhone app.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION="${1:-export}"
VERSION="${PAPERCUP_MARKETING_VERSION:-1.0.0}"
BUILD_NUMBER="${PAPERCUP_BUILD_NUMBER:-1}"
RUN_ID="${PAPERCUP_RELEASE_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RELEASE_ROOT="${PAPERCUP_RELEASE_DIR:-$REPO_ROOT/ios/build/release/$VERSION-$BUILD_NUMBER-$RUN_ID}"
ARCHIVE_PATH="$RELEASE_ROOT/Papercusp.xcarchive"
EXPORT_DIR="$RELEASE_ROOT/export"
SIGNING_STYLE="${PAPERCUP_SIGNING_STYLE:-automatic}"
APP_BUNDLE_ID="${PAPERCUP_APP_BUNDLE_ID:-com.papercuspai.operator.mobile}"

usage() {
    cat >&2 <<'EOF'
Usage: release-ios.sh [preflight|archive|export|validate|upload]

Environment for signing:
  PAPERCUP_DEVELOPMENT_TEAM       Apple Developer team ID
  PAPERCUP_BUILD_NUMBER           Monotonically increasing App Store build number
  PAPERCUP_SIGNING_STYLE          automatic (default: the Mac's Xcode account)
                                  or manual (CI: installed identity + profile)
  PAPERCUP_PROVISIONING_PROFILE   App Store profile name (manual signing only)
  PAPERCUP_CI_KEYCHAIN            Keychain holding the identity (optional)

Environment for validate/upload:
  PAPERCUP_IPA_PATH               Explicit path to the exported IPA
  APP_STORE_CONNECT_API_KEY_ID    App Store Connect API key ID
  APP_STORE_CONNECT_API_ISSUER_ID App Store Connect issuer ID
  APP_STORE_CONNECT_API_KEY_PATH  Optional explicit AuthKey_*.p8 path
EOF
}

preflight() {
    "$REPO_ROOT/tools/build-scripts/verify-ios-release.sh" --require-current-sdk
    command -v xcodegen >/dev/null || { echo "ERROR: xcodegen is required" >&2; exit 1; }
    command -v rustup >/dev/null || { echo "ERROR: rustup is required" >&2; exit 1; }
}

require_signing() {
    : "${PAPERCUP_DEVELOPMENT_TEAM:?Set PAPERCUP_DEVELOPMENT_TEAM to the Apple Developer team ID}"
    case "$SIGNING_STYLE" in
        automatic) ;;
        manual)
            : "${PAPERCUP_PROVISIONING_PROFILE:?Set PAPERCUP_PROVISIONING_PROFILE to the App Store profile name for manual signing}"
            ;;
        *)
            echo "ERROR: PAPERCUP_SIGNING_STYLE must be automatic or manual, got: $SIGNING_STYLE" >&2
            exit 1
            ;;
    esac
    # With an explicit CI keychain, look for the identity there rather than
    # trusting whatever else is on the search list.
    if ! security find-identity -v -p codesigning ${PAPERCUP_CI_KEYCHAIN:+"$PAPERCUP_CI_KEYCHAIN"} \
        | grep -q 'Apple Distribution'; then
        echo "ERROR: no valid Apple Distribution signing identity is installed" >&2
        exit 1
    fi
}

# Automatic signing needs an Xcode account and may refresh profiles. Manual
# signing must not: CI has no account, and the installed App Store profile is
# the only one allowed. The profile reaches the app target alone through
# PAPERCUP_APP_PROVISIONING_PROFILE (ios/project.yml); a command-line
# PROVISIONING_PROFILE_SPECIFIER would apply to every target and fail on the
# PapercupCore framework and the Swift package products.
set_signing_args() {
    if [ "$SIGNING_STYLE" = manual ]; then
        SIGNING_ARGS=(
            CODE_SIGN_STYLE=Manual
            "CODE_SIGN_IDENTITY=Apple Distribution"
            "PAPERCUP_APP_PROVISIONING_PROFILE=$PAPERCUP_PROVISIONING_PROFILE"
        )
        if [ -n "${PAPERCUP_CI_KEYCHAIN:-}" ]; then
            SIGNING_ARGS+=("OTHER_CODE_SIGN_FLAGS=--keychain $PAPERCUP_CI_KEYCHAIN")
        fi
    else
        SIGNING_ARGS=(-allowProvisioningUpdates)
    fi
}

# Manual export options are derived from the tracked ExportOptions.plist so the
# method and symbol settings stay single-sourced; only signing fields differ.
write_export_options() {
    if [ "$SIGNING_STYLE" != manual ]; then
        EXPORT_OPTIONS="$REPO_ROOT/ios/ExportOptions.plist"
        return
    fi
    EXPORT_OPTIONS="$RELEASE_ROOT/ExportOptions.manual.plist"
    python3 - "$REPO_ROOT/ios/ExportOptions.plist" "$EXPORT_OPTIONS" \
        "$PAPERCUP_DEVELOPMENT_TEAM" "$APP_BUNDLE_ID" "$PAPERCUP_PROVISIONING_PROFILE" <<'PY'
import plistlib
import sys

source, target, team, bundle_id, profile = sys.argv[1:]
with open(source, "rb") as handle:
    options = plistlib.load(handle)
options.update({
    "signingStyle": "manual",
    "teamID": team,
    "signingCertificate": "Apple Distribution",
    "provisioningProfiles": {bundle_id: profile},
})
with open(target, "wb") as handle:
    plistlib.dump(options, handle)
PY
}

build_archive() {
    preflight
    require_signing
    set_signing_args
    mkdir -p "$RELEASE_ROOT"
    "$REPO_ROOT/tools/build-scripts/build-ios.sh"
    (cd "$REPO_ROOT/ios" && xcodegen generate)
    xcodebuild archive \
        -project "$REPO_ROOT/ios/Papercup.xcodeproj" \
        -scheme Papercup \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$ARCHIVE_PATH" \
        "${SIGNING_ARGS[@]}" \
        DEVELOPMENT_TEAM="$PAPERCUP_DEVELOPMENT_TEAM" \
        MARKETING_VERSION="$VERSION" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
    echo "OK: archive $ARCHIVE_PATH"
}

export_ipa() {
    build_archive
    mkdir -p "$EXPORT_DIR"
    write_export_options
    if [ "$SIGNING_STYLE" = manual ]; then
        export_args=()
    else
        export_args=(-allowProvisioningUpdates)
    fi
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        ${export_args[@]+"${export_args[@]}"}
    ipa_path="$(find "$EXPORT_DIR" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
    if [ -z "$ipa_path" ]; then
        echo "ERROR: export completed without an IPA in $EXPORT_DIR" >&2
        exit 1
    fi
    echo "OK: IPA $ipa_path"
}

configure_api_key() {
    : "${APP_STORE_CONNECT_API_KEY_ID:?Set APP_STORE_CONNECT_API_KEY_ID}"
    : "${APP_STORE_CONNECT_API_ISSUER_ID:?Set APP_STORE_CONNECT_API_ISSUER_ID}"
    if [ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]; then
        if [ ! -f "$APP_STORE_CONNECT_API_KEY_PATH" ]; then
            echo "ERROR: APP_STORE_CONNECT_API_KEY_PATH does not exist" >&2
            exit 1
        fi
        key_dir="$(dirname "$APP_STORE_CONNECT_API_KEY_PATH")"
        expected="$key_dir/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
        if [ "$APP_STORE_CONNECT_API_KEY_PATH" != "$expected" ]; then
            echo "ERROR: API key must be named AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8" >&2
            exit 1
        fi
        export API_PRIVATE_KEYS_DIR="$key_dir"
    fi
}

require_ipa() {
    : "${PAPERCUP_IPA_PATH:?Set PAPERCUP_IPA_PATH to the exact exported IPA}"
    if [ ! -f "$PAPERCUP_IPA_PATH" ]; then
        echo "ERROR: PAPERCUP_IPA_PATH does not exist: $PAPERCUP_IPA_PATH" >&2
        exit 1
    fi
}

validate_ipa() {
    preflight
    require_ipa
    configure_api_key
    xcrun altool --validate-app --type ios --file "$PAPERCUP_IPA_PATH" \
        --apiKey "$APP_STORE_CONNECT_API_KEY_ID" \
        --apiIssuer "$APP_STORE_CONNECT_API_ISSUER_ID"
}

upload_ipa() {
    validate_ipa
    xcrun altool --upload-app --type ios --file "$PAPERCUP_IPA_PATH" \
        --apiKey "$APP_STORE_CONNECT_API_KEY_ID" \
        --apiIssuer "$APP_STORE_CONNECT_API_ISSUER_ID"
}

case "$ACTION" in
    preflight) preflight ;;
    archive) build_archive ;;
    export) export_ipa ;;
    validate) validate_ipa ;;
    upload) upload_ipa ;;
    -h|--help|help) usage ;;
    *) usage; echo "ERROR: unknown action: $ACTION" >&2; exit 2 ;;
esac

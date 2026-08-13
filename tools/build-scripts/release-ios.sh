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

usage() {
    cat >&2 <<'EOF'
Usage: release-ios.sh [preflight|archive|export|validate|upload]

Environment for signing:
  PAPERCUP_DEVELOPMENT_TEAM       Apple Developer team ID
  PAPERCUP_BUILD_NUMBER           Monotonically increasing App Store build number

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
    if ! security find-identity -v -p codesigning | grep -q 'Apple Distribution'; then
        echo "ERROR: no valid Apple Distribution signing identity is installed" >&2
        exit 1
    fi
}

build_archive() {
    preflight
    require_signing
    mkdir -p "$RELEASE_ROOT"
    "$REPO_ROOT/tools/build-scripts/build-ios.sh"
    (cd "$REPO_ROOT/ios" && xcodegen generate)
    xcodebuild archive \
        -project "$REPO_ROOT/ios/Papercup.xcodeproj" \
        -scheme Papercup \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$ARCHIVE_PATH" \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$PAPERCUP_DEVELOPMENT_TEAM" \
        MARKETING_VERSION="$VERSION" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
    echo "OK: archive $ARCHIVE_PATH"
}

export_ipa() {
    build_archive
    mkdir -p "$EXPORT_DIR"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$REPO_ROOT/ios/ExportOptions.plist" \
        -allowProvisioningUpdates
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

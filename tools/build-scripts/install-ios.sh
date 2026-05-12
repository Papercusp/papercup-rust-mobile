#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build the iOS app + install + launch on the iPhone 16 simulator.
# Uses per-target build to dodge the Xcode 16.2 destination-resolver
# race that breaks `xcodebuild -scheme` since Sentry SwiftPM landed.
#
# Assumes ./build-ios.sh has already rebuilt PapercupCore.xcframework
# (or call `make build-ios install-ios`).
#
# PAPERCUP_IOS_SIM_UDID overrides the sim picker (first iPhone 16).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT/ios"

if [ -z "${PAPERCUP_IOS_SIM_UDID:-}" ]; then
    PAPERCUP_IOS_SIM_UDID=$(xcrun simctl list devices available \
        | awk -F '[()]' '/iPhone 16 \(/{print $2; exit}')
fi
if [ -z "$PAPERCUP_IOS_SIM_UDID" ]; then
    echo "ERROR: no iPhone 16 simulator found and PAPERCUP_IOS_SIM_UDID unset" >&2
    exit 1
fi
echo "▶ sim: $PAPERCUP_IOS_SIM_UDID"

xcrun simctl boot "$PAPERCUP_IOS_SIM_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$PAPERCUP_IOS_SIM_UDID" -b 2>/dev/null || true

# Skip xcodegen if the project already exists — regenerating wipes
# Xcode's destination cache and re-triggers the race.
if [ ! -d Papercup.xcodeproj ]; then
    xcodegen generate >/dev/null
fi

# Per-target build, NOT -scheme. -scheme trips the destination-
# resolver race; -target talks straight to the build system and
# uses the active SDK without iterating destinations.
#
# Pin ARCHS to the host architecture. On x86_64 macOS VMs, attempting
# to build arm64-simulator slices fails (clang -cc1 frontend can't
# find precompiled module files for the wrong arch). Detect the host
# and pass ARCHS explicitly so Xcode doesn't iterate fat archs.
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
    arm64|aarch64) SIM_ARCH=arm64 ;;
    x86_64)        SIM_ARCH=x86_64 ;;
    *)             SIM_ARCH="$HOST_ARCH" ;;
esac
echo "▶ building Papercup target (Debug, iphonesimulator, ARCHS=$SIM_ARCH, no-explicit-modules)"
# Disable Xcode 16's ExplicitModules feature — it hashes-and-references
# precompiled .pcm module files that frequently end up missing on
# disk-pressured or x86 macOS VMs, surfacing as
# "module file 'Foundation-…pcm' not found".
# The implicit-modules path (pre-Xcode-16 default) is slower but works.
# Use -scheme (not -target) so xcodebuild resolves the SwiftPM binary
# dependency graph and builds LiveKitUniFFI before LiveKit.swift tries
# to import it. With -target, fresh DerivedData hits
# "no such module 'LiveKitUniFFI'".
#
# -clonedSourcePackagesDirPath isolates SwiftPM checkouts outside of
# DerivedData so blowing away DerivedData doesn't force a re-clone.
# Critical on disk-pressured VMs where the LiveKit fork (1.3 GB)
# would otherwise need re-fetching on every retry.
#
# -derivedDataPath ios/build/dd keeps build products inside the repo
# (older script convention) so the APP-path resolve below still works.
SPM_CACHE="${PAPERCUP_IOS_SPM_CACHE:-$HOME/spm-cache}"
mkdir -p "$SPM_CACHE"
xcodebuild -project Papercup.xcodeproj -scheme Papercup \
    -sdk iphonesimulator -configuration Debug \
    -destination "platform=iOS Simulator,id=$PAPERCUP_IOS_SIM_UDID" \
    -derivedDataPath build/dd \
    -clonedSourcePackagesDirPath "$SPM_CACHE" \
    ARCHS="$SIM_ARCH" VALID_ARCHS="$SIM_ARCH" ONLY_ACTIVE_ARCH=NO \
    CLANG_ENABLE_EXPLICIT_MODULES=NO \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO \
    build \
    > build/install-ios.log 2>&1 || {
    echo "ERROR: build failed; tail of build/install-ios.log:" >&2
    tail -30 build/install-ios.log >&2
    exit 1
}

APP="$REPO_ROOT/ios/build/dd/Build/Products/Debug-iphonesimulator/Papercup.app"
if [ ! -d "$APP" ]; then
    echo "ERROR: built app not at $APP" >&2
    exit 1
fi

BUNDLE_ID="com.papercuspai.operator.mobile"
echo "▶ installing $APP to sim"
xcrun simctl install "$PAPERCUP_IOS_SIM_UDID" "$APP"

echo "▶ launching $BUNDLE_ID"
xcrun simctl launch "$PAPERCUP_IOS_SIM_UDID" "$BUNDLE_ID"

echo "▶ done. Verify:"
echo "    bp=\$(xcrun simctl get_app_container $PAPERCUP_IOS_SIM_UDID $BUNDLE_ID)"
echo "    stat -f \"installed: %Sm\" \"\$bp/Papercup\""

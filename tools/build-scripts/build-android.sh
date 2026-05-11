#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-compile papercup-bindings for all 4 Android ABIs and drop the
# resulting libpapercup.so files into android/app/src/main/jniLibs.
# Then run gradle to assemble the debug APK.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# NDK path. Prefer ANDROID_NDK_HOME, fall back to the version we know
# is on this dev machine.
: "${ANDROID_NDK_HOME:=$HOME/Android/Sdk/ndk/27.0.12077973}"
export ANDROID_NDK_HOME

if [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "ERROR: ANDROID_NDK_HOME not found at $ANDROID_NDK_HOME" >&2
    echo "Set ANDROID_NDK_HOME to your NDK install (Android Studio: Settings → SDK → SDK Tools → NDK)." >&2
    exit 1
fi

mkdir -p android/app/src/main/jniLibs

echo "==> Cross-compiling papercup-bindings for all Android ABIs (release)"
cargo ndk \
    -t arm64-v8a \
    -t armeabi-v7a \
    -t x86 \
    -t x86_64 \
    -o android/app/src/main/jniLibs \
    build -p papercup-bindings --release

echo "==> Built jniLibs:"
find android/app/src/main/jniLibs -name '*.so' -printf '    %p (%s bytes)\n'

# Guard: every ABI's .so must be at least as fresh as the generated Kotlin
# bindings, otherwise the APK ships with stale symbols and JNA throws
# UnsatisfiedLinkError on the first checksum call (see history: 2026-05-11
# pair-screen crash from missing uniffi_papercup_checksum_method_synccache_get).
KT_BINDINGS="android/app/src/main/kotlin/uniffi/papercup/papercup.kt"
if [ -f "$KT_BINDINGS" ]; then
    KT_MTIME=$(stat -c %Y "$KT_BINDINGS")
    STALE=()
    for so in android/app/src/main/jniLibs/*/libpapercup.so; do
        SO_MTIME=$(stat -c %Y "$so")
        if [ "$SO_MTIME" -lt "$KT_MTIME" ]; then
            STALE+=("$so")
        fi
    done
    if [ "${#STALE[@]}" -gt 0 ]; then
        echo "ERROR: jniLibs older than $KT_BINDINGS — APK would ship stale UniFFI symbols:" >&2
        printf '  %s\n' "${STALE[@]}" >&2
        exit 1
    fi
fi

if [ -f android/gradlew ]; then
    echo "==> Assembling Android debug APK"
    cd android
    ./gradlew assembleDebug
    echo "==> APK at: $REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
else
    echo "==> Skipping APK assemble: android/gradlew not present yet."
    echo "    Run \`gradle wrapper --gradle-version 8.10\` from android/ to install the wrapper."
fi

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-compile papercup-bindings for all 4 Android ABIs and drop the
# resulting libpapercup.so files into android/app/src/main/jniLibs.
# Then run Gradle for either a developer debug APK (the default) or the
# public-release APK + AAB (`build-android.sh release`).
set -euo pipefail

resolve_android_sdk() {
    local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
    if [ -z "$sdk_root" ] || [ ! -d "$sdk_root" ]; then
        echo "ERROR: Android SDK not found; set ANDROID_SDK_ROOT or ANDROID_HOME" >&2
        return 1
    fi
    ANDROID_SDK_ROOT="$sdk_root"
    ANDROID_HOME="$sdk_root"
    export ANDROID_SDK_ROOT ANDROID_HOME
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Reuse CI's executor for release/debug writers; inherited custody is verified
# before any shared JNI, APK, AAB or manifest is removed or rewritten.
if [[ -z "${PAPERCUP_ANDROID_EXECUTOR_FD:-}" ]]; then
    exec python3 tools/android-ci.py --exclusive-command bash "$0" "$@"
fi
python3 tools/android-ci.py --verify-executor

BUILD_MODE="${1:-debug}"
case "$BUILD_MODE" in
    debug|release) ;;
    *)
        echo "usage: $0 [debug|release]" >&2
        exit 2
        ;;
esac

RELEASE_VERSION="${PAPERCUP_RELEASE_VERSION:-}"
RELEASE_APK="$REPO_ROOT/android/app/build/outputs/apk/release/app-release.apk"
RELEASE_AAB="$REPO_ROOT/android/app/build/outputs/bundle/release/app-release.aab"
RELEASE_PROVENANCE="$REPO_ROOT/android/app/build/outputs/papercusp-release-provenance.json"
if [ "$BUILD_MODE" = "release" ]; then
    [ -n "$RELEASE_VERSION" ] || {
        echo "ERROR: PAPERCUP_RELEASE_VERSION is required for a release build" >&2
        exit 2
    }
    # A failed/partial Gradle invocation must not leave the preceding release as
    # a candidate. The manifest is written atomically only after both outputs pass
    # every release verification below.
    rm -f "$RELEASE_APK" "$RELEASE_AAB" "$RELEASE_PROVENANCE"
fi

resolve_android_sdk
: "${ANDROID_NDK_HOME:=$ANDROID_SDK_ROOT/ndk/27.0.12077973}"
export ANDROID_NDK_HOME

if [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "ERROR: ANDROID_NDK_HOME not found at $ANDROID_NDK_HOME" >&2
    echo "Set ANDROID_NDK_HOME to your NDK install (Android Studio: Settings → SDK → SDK Tools → NDK)." >&2
    exit 1
fi
if ! command -v cargo-ndk >/dev/null 2>&1 && ! cargo ndk --version >/dev/null 2>&1; then
    echo "ERROR: cargo-ndk is required (cargo install cargo-ndk)" >&2
    exit 1
fi

ANDROID_ABIS=(arm64-v8a armeabi-v7a x86 x86_64)
JNI_LIBS=()
for abi in "${ANDROID_ABIS[@]}"; do
    lib="android/app/src/main/jniLibs/$abi/libpapercup.so"
    mkdir -p "$(dirname "$lib")"
    # The destination is generated. Removing it before cargo-ndk runs means a
    # partial/no-copy build cannot silently package a library left by an older
    # invocation (the May 2026 pair-screen crash class).
    rm -f "$lib"
    JNI_LIBS+=("$lib")
done

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

# Guard the actual contract, not filesystem time. UniFFI writes every expected
# API checksum symbol into the generated Kotlin bindings and exports the same
# symbols from libpapercup.so. Cached Cargo artifacts may legitimately predate a
# freshly-regenerated, byte-identical papercup.kt; mtimes therefore reject good
# builds and say nothing about ABI compatibility (EI-20111976297906819).
KT_BINDINGS="android/app/src/main/kotlin/uniffi/papercup/papercup.kt"
tools/build-scripts/verify-android-uniffi-abi.sh "$KT_BINDINGS" "${JNI_LIBS[@]}"

verify_packaged_abis() {
    local archive="$1"
    local prefix="$2"
    local expected actual

    expected="$(printf '%s\n' "${ANDROID_ABIS[@]}" | sort)"
    actual="$(unzip -Z1 "$archive" \
        | sed -n "s#^${prefix}\\([^/]*\\)/.*\\.so\$#\\1#p" \
        | sort -u)"

    if [ "$actual" != "$expected" ]; then
        echo "ERROR: unexpected native ABI set in $archive" >&2
        echo "Expected:" >&2
        printf '    %s\n' "${ANDROID_ABIS[@]}" >&2
        echo "Found:" >&2
        printf '%s\n' "$actual" | sed 's/^/    /' >&2
        exit 1
    fi

    echo "==> Verified packaged ABIs in $(basename "$archive"): ${ANDROID_ABIS[*]}"
}

verify_16kb_alignment() {
    local apk="$1"
    local variant="${2:-release}"
    local variant_title="${variant^}"
    local native_root="$REPO_ROOT/android/app/build/intermediates/merged_native_libs/$variant/merge${variant_title}NativeLibs/out/lib"
    local objdump zipalign power so
    local checked=0

    objdump="$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" \
        -path '*/bin/llvm-objdump' -type f -print -quit)"
    zipalign="$(find "$ANDROID_SDK_ROOT/build-tools" -mindepth 2 -maxdepth 2 \
        -name zipalign -type f -print | sort -V | tail -n 1)"

    if [ -z "$objdump" ] || [ -z "$zipalign" ]; then
        echo "ERROR: 16 KB verification requires llvm-objdump and zipalign" >&2
        exit 1
    fi

    for so in "$native_root/arm64-v8a"/*.so "$native_root/x86_64"/*.so; do
        if [ ! -f "$so" ]; then
            echo "ERROR: missing 64-bit native libraries under $native_root" >&2
            exit 1
        fi
        while read -r power; do
            if [ "$power" -lt 14 ]; then
                echo "ERROR: $(basename "$so") has a LOAD segment aligned to 2**$power, not 2**14" >&2
                exit 1
            fi
        done < <("$objdump" -p "$so" | awk '/LOAD/ { sub(/^.*2\*\*/, ""); print }')
        checked=$((checked + 1))
    done

    "$zipalign" -c -P 16 -v 4 "$apk" >/dev/null
    echo "==> Verified 16 KB alignment for $checked 64-bit shared libraries and $(basename "$apk")"
}

if [ -f android/gradlew ]; then
    cd android
    if [ "$BUILD_MODE" = "release" ]; then
        # Refuse before the expensive build: provenance write repeats this gate.
        "$REPO_ROOT/tools/build-scripts/android-release-provenance.sh" checks-gate
        echo "==> Assembling Android release APK + AAB"
        ./gradlew :app:assembleRelease :app:bundleRelease
        verify_packaged_abis \
            "$RELEASE_APK" \
            'lib/'
        verify_packaged_abis \
            "$RELEASE_AAB" \
            'base/lib/'
        verify_16kb_alignment "$RELEASE_APK"
        "$REPO_ROOT/tools/build-scripts/android-release-provenance.sh" write \
            "$RELEASE_VERSION" "$RELEASE_APK" "$RELEASE_AAB"
        echo "==> Release APK: $RELEASE_APK"
        echo "==> Release AAB: $RELEASE_AAB"
        echo "==> Provenance: $RELEASE_PROVENANCE"
    else
        echo "==> Assembling Android debug APK"
        ./gradlew :app:assembleDebug
        verify_packaged_abis \
            "$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk" \
            'lib/'
        verify_16kb_alignment \
            "$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk" \
            debug
        echo "==> Debug APK: $REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
    fi
else
    echo "==> Skipping APK assemble: android/gradlew not present yet."
    echo "    Run \`gradle wrapper --gradle-version 8.10\` from android/ to install the wrapper."
fi

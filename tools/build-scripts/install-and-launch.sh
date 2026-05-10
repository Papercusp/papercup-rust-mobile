#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Install the freshly-built APK on every connected adb device — physical
# phones first, then booting the `papercusp-test` emulator if no device
# of that kind is connected. Launches MainActivity on each.
#
# Auto-runs after `make build-android` (see Makefile install-android
# target). Idempotent — safe to run any time the APK is already there.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APK="$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
PKG="com.papercuspai.operator.mobile"
ACT="$PKG/.MainActivity"
AVD_NAME="${PAPERCUP_AVD:-papercusp-test}"
ANDROID_SDK="${ANDROID_HOME:-$HOME/Android/Sdk}"

if [ ! -f "$APK" ]; then
    echo "ERROR: APK not found at $APK; run 'make build-android' first." >&2
    exit 1
fi

# Make sure adb is alive, then list devices we'll touch.
adb start-server >/dev/null 2>&1 || true

mapfile -t DEVS < <(adb devices | awk 'NR>1 && $2=="device"{print $1}')

# Ensure the emulator is up if no emulator-* device is currently listed.
if ! printf '%s\n' "${DEVS[@]}" | grep -q '^emulator-'; then
    if [ -x "$ANDROID_SDK/emulator/emulator" ]; then
        if "$ANDROID_SDK/emulator/emulator" -list-avds | grep -qx "$AVD_NAME"; then
            echo "==> Booting emulator $AVD_NAME (no emulator-* device detected)"
            nohup "$ANDROID_SDK/emulator/emulator" \
                -avd "$AVD_NAME" \
                -netdelay none -netspeed full \
                -gpu swiftshader_indirect \
                >/tmp/emu.log 2>&1 &
            disown
            echo -n "==> Waiting for boot"
            for _ in $(seq 1 90); do
                STATE=$(adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
                if [ "$STATE" = "1" ]; then echo " — ready"; break; fi
                echo -n "."
                sleep 1
            done
            mapfile -t DEVS < <(adb devices | awk 'NR>1 && $2=="device"{print $1}')
        else
            echo "==> No AVD named '$AVD_NAME' — skipping emulator boot. Run 'avdmanager create avd' to create one." >&2
        fi
    fi
fi

if [ ${#DEVS[@]} -eq 0 ]; then
    echo "ERROR: no devices to install on (no phone, no emulator)." >&2
    exit 2
fi

for d in "${DEVS[@]}"; do
    echo "==> [$d] install + launch"
    # Force-stop first so launch always shows the new build state.
    adb -s "$d" shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb -s "$d" install -r -d "$APK" 2>&1 | grep -E "Success|Failure" || true
    adb -s "$d" shell am start -n "$ACT" >/dev/null
done

echo "==> Done. Devices:"
printf '    %s\n' "${DEVS[@]}"

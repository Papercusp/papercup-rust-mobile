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
APK="${PAPERCUP_ANDROID_APK:-$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk}"
PKG="com.papercuspai.operator.mobile"
ACT="$PKG/.MainActivity"
AVD_NAME="${PAPERCUP_AVD:-papercusp-test}"
ANDROID_SDK="${ANDROID_HOME:-$HOME/Android/Sdk}"
EMULATOR_UNIT=""

launch_emulator() {
    local emulator="$ANDROID_SDK/emulator/emulator"
    local -a emulator_args=(
        -avd "$AVD_NAME"
        -netdelay none
        -netspeed full
        -gpu swiftshader_indirect
        # Match the native CI fixture. An AVD's suffixed hw.ramSize can be
        # parsed as 256 MiB; explicit guest memory avoids that boot-loop.
        -memory 4096
        -feature GLDirectMem,HasSharedSlotsHostMemoryAllocator
    )

    # A plain `nohup … & disown` only detaches from the shell. Agent/CI command
    # runners commonly place the shell and every descendant in one transient
    # systemd cgroup, then stop that whole cgroup when the command returns. The
    # emulator can therefore boot, accept the APK, and disappear immediately
    # after this script prints a false-success verdict. A transient USER service
    # is a sibling of the invoking command scope, so the visible emulator keeps
    # running after this installer exits. The fallback preserves macOS and other
    # hosts without a systemd user manager.
    if command -v systemd-run >/dev/null 2>&1 \
        && command -v systemctl >/dev/null 2>&1 \
        && systemctl --user show-environment >/dev/null 2>&1; then
        local unit_suffix unit
        unit_suffix="$(printf '%s' "$AVD_NAME" | tr -cs 'A-Za-z0-9_.-' '-')"
        unit="papercusp-android-emulator-${unit_suffix%.}"
        local -a service_env=(--setenv="DISPLAY=${DISPLAY:-:0}")
        [[ -n "${XAUTHORITY:-}" ]] && service_env+=(--setenv="XAUTHORITY=$XAUTHORITY")
        [[ -n "${WAYLAND_DISPLAY:-}" ]] && service_env+=(--setenv="WAYLAND_DISPLAY=$WAYLAND_DISPLAY")

        systemctl --user reset-failed "$unit.service" >/dev/null 2>&1 || true
        systemd-run --user --unit="$unit" --collect --service-type=exec \
            --property="Description=Papercup Android Emulator ($AVD_NAME)" \
            "${service_env[@]}" \
            "$emulator" "${emulator_args[@]}" >/dev/null
        EMULATOR_UNIT="$unit.service"
        echo "==> Emulator service: $unit.service (logs: journalctl --user -u $unit.service)"
    else
        echo "==> WARNING: no systemd user manager; emulator lifetime follows the host session" >&2
        nohup "$emulator" "${emulator_args[@]}" >/tmp/emu.log 2>&1 &
        disown
    fi
}

if [ ! -f "$APK" ]; then
    echo "ERROR: APK not found at $APK; run 'make build-android' first." >&2
    exit 1
fi

# Make sure adb is alive, then list devices we'll touch.
adb start-server >/dev/null 2>&1 || true

mapfile -t DEVS < <(adb devices | awk 'NR>1 && $2=="device"{print $1}')

# CI owns one emulator. Never install its candidate onto a peer device.
if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    printf '%s\n' "${DEVS[@]}" | grep -Fxq "$ANDROID_SERIAL" || {
        echo "ERROR: explicitly selected device is not connected: $ANDROID_SERIAL" >&2
        exit 2
    }
    DEVS=("$ANDROID_SERIAL")
fi

# Ensure the emulator is up if no emulator-* device is currently listed.
if [[ -z "${ANDROID_SERIAL:-}" ]] && ! printf '%s\n' "${DEVS[@]}" | grep -q '^emulator-'; then
    if [ -x "$ANDROID_SDK/emulator/emulator" ]; then
        if "$ANDROID_SDK/emulator/emulator" -list-avds | grep -qx "$AVD_NAME"; then
            echo "==> Booting emulator $AVD_NAME (no emulator-* device detected)"
            launch_emulator
            echo -n "==> Waiting for boot"
            boot_ready=0
            for _ in $(seq 1 90); do
                # A transport or sys.boot_completed snapshot is not proof that
                # the emulator producer survived. Collected transient units
                # may disappear entirely after an early host crash.
                if [[ -n "$EMULATOR_UNIT" ]] \
                    && ! systemctl --user is-active --quiet "$EMULATOR_UNIT"; then
                    echo >&2
                    echo "ERROR: emulator service exited before boot completed: $EMULATOR_UNIT" >&2
                    echo "Inspect: journalctl --user -u $EMULATOR_UNIT" >&2
                    exit 1
                fi
                STATE=$(adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
                if [ "$STATE" = "1" ]; then
                    boot_ready=1
                    echo " — ready"
                    break
                fi
                echo -n "."
                sleep 1
            done
            if [[ "$boot_ready" != 1 ]]; then
                echo >&2
                echo "ERROR: Android boot did not complete; APK installation was not attempted." >&2
                exit 1
            fi
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
    # An install rejection must stop the journey, rather than launch the
    # previously installed app and certify it as the newly built candidate.
    if ! install_output="$(adb -s "$d" install -r "$APK" 2>&1)"; then
        printf '%s\n' "$install_output" >&2
        echo "ERROR: [$d] APK installation failed; activity was not launched." >&2
        exit 1
    fi
    printf '%s\n' "$install_output"
    # Activity Manager can report an error while adb still exits zero.
    # Waiting for its explicit status proves this candidate actually opened.
    if ! launch_output="$(adb -s "$d" shell am start -W -n "$ACT" 2>&1)" \
        || ! printf '%s\n' "$launch_output" | tr -d '\r' | grep -Eq '^Status: ok[[:space:]]*$'; then
        printf '%s\n' "$launch_output" >&2
        echo "ERROR: [$d] activity launch was not confirmed." >&2
        exit 1
    fi
    printf '%s\n' "$launch_output"
done

echo "==> Done. Devices:"
printf '    %s\n' "${DEVS[@]}"

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Regression guard: a command-runner cgroup must not own the Android emulator.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/tools/build-scripts/install-and-launch.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/sdk/emulator" "$TMP_ROOT/home" "$TMP_ROOT/state"
: > "$TMP_ROOT/app-debug.apk"

cat > "$TMP_ROOT/sdk/emulator/emulator" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-list-avds" ]]; then
    printf '%s\n' papercusp-test
    exit 0
fi
echo 'emulator binary was launched directly instead of through systemd-run' >&2
exit 90
SH

cat > "$TMP_ROOT/bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
    *show-environment*|*reset-failed*) exit 0 ;;
    *) exit 0 ;;
esac
SH

cat > "$TMP_ROOT/bin/systemd-run" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$PAPERCUP_TEST_STATE/systemd-run.args"
SH

cat > "$TMP_ROOT/bin/adb" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    start-server) exit 0 ;;
    devices)
        printf 'List of devices attached\n'
        [[ -f "$PAPERCUP_TEST_STATE/systemd-run.args" ]] \
            && printf 'emulator-5554\tdevice\n'
        ;;
    -s)
        case "$*" in
            *'shell getprop sys.boot_completed'*) printf '1\n' ;;
            *' install '*) printf 'Success\n' ;;
            *) exit 0 ;;
        esac
        ;;
    *) exit 0 ;;
esac
SH

chmod +x "$TMP_ROOT/bin/adb" "$TMP_ROOT/bin/systemctl" "$TMP_ROOT/bin/systemd-run" \
    "$TMP_ROOT/sdk/emulator/emulator"

PATH="$TMP_ROOT/bin:$PATH" \
HOME="$TMP_ROOT/home" \
ANDROID_HOME="$TMP_ROOT/sdk" \
DISPLAY=:42 \
PAPERCUP_ANDROID_APK="$TMP_ROOT/app-debug.apk" \
PAPERCUP_TEST_STATE="$TMP_ROOT/state" \
    "$SCRIPT" > "$TMP_ROOT/output.log"

args="$TMP_ROOT/state/systemd-run.args"
[[ -f "$args" ]] || fail 'systemd-run was not invoked'
grep -Fx -- '--user' "$args" >/dev/null || fail 'emulator was not launched as a user service'
grep -Fx -- '--service-type=exec' "$args" >/dev/null || fail 'service start did not wait for exec'
grep -Fx -- '--setenv=DISPLAY=:42' "$args" >/dev/null || fail 'visible display was not forwarded'
grep -Fx -- "$TMP_ROOT/sdk/emulator/emulator" "$args" >/dev/null || fail 'emulator executable missing'
grep -Fx -- '-avd' "$args" >/dev/null || fail 'AVD flag missing'
grep -Fx -- 'papercusp-test' "$args" >/dev/null || fail 'AVD name missing'
grep -F 'Emulator service: papercusp-android-emulator-papercusp-test.service' "$TMP_ROOT/output.log" >/dev/null \
    || fail 'durable service identity was not reported'
grep -F 'Done. Devices:' "$TMP_ROOT/output.log" >/dev/null || fail 'install flow did not complete'

echo 'install-and-launch lifecycle tests: 1 passed'

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Regression tests for check-ios-build-host-health.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/tools/build-scripts/check-ios-build-host-health.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "$TMP_ROOT/bin"

cat > "$TMP_ROOT/bin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${TEST_UNAME:-Darwin}"
SH

cat > "$TMP_ROOT/bin/ps" <<'SH'
#!/usr/bin/env bash
case "${TEST_PS_SCENARIO:-healthy}" in
    healthy)
        printf '%s\n' \
            '  0.0 /System/Library/Frameworks/VideoToolbox.framework/XPCServices/VTDecoderXPCService' \
            ' 11.5 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer'
        ;;
    media)
        printf '%s\n' \
            ' 41.0 /System/Library/Frameworks/VideoToolbox.framework/XPCServices/VTDecoderXPCService' \
            ' 36.0 /System/Library/Frameworks/VideoToolbox.framework/XPCServices/VTDecoderXPCService' \
            ' 10.5 /System/Library/ExtensionKit/Extensions/WallpaperAerials.appex/Contents/MacOS/WallpaperAerials' \
            ' 99.8 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer'
        ;;
    window-server)
        printf '%s\n' \
            '  0.0 /System/Library/Frameworks/VideoToolbox.framework/XPCServices/VTDecoderXPCService' \
            ' 86.0 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer'
        ;;
esac
SH

cat > "$TMP_ROOT/bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH

chmod +x "$TMP_ROOT/bin/uname" "$TMP_ROOT/bin/ps" "$TMP_ROOT/bin/sleep"

run_guard() {
    PATH="$TMP_ROOT/bin:/usr/bin:/bin" PAPERCUP_IOS_HOST_HEALTH_SAMPLES=1 \
        TEST_UNAME="$1" TEST_PS_SCENARIO="$2" "$GUARD" 2>&1
}

run_guard Linux media >/dev/null || fail 'non-macOS host should be a no-op'
run_guard Darwin healthy | grep -F 'iOS build host health' >/dev/null || fail 'healthy macOS host was rejected'

if output="$(run_guard Darwin media)"; then
    fail 'saturated media workers were accepted'
fi
grep -F 'VTDecoderXPCService and WallpaperAerials' <<<"$output" >/dev/null || fail 'media failure omitted exact writers'

if output="$(run_guard Darwin window-server)"; then
    fail 'saturated WindowServer was accepted'
fi
grep -F 'WindowServer is saturated' <<<"$output" >/dev/null || fail 'WindowServer failure was not actionable'

echo 'iOS build host health tests: 4 passed'

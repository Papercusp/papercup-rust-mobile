#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fail before an expensive iOS build when macOS video-wallpaper/first-login
# workers are already saturating the display stack.
set -euo pipefail

# Named remote execution lane used by the template contract: avis-imac.
if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: macOS is required (delegate to named host avis-imac)." >&2
    exit 2
fi
command -v xcodebuild >/dev/null || { echo "ERROR: Xcode is required" >&2; exit 2; }
command -v xcodegen >/dev/null || { echo "ERROR: xcodegen is required" >&2; exit 2; }
command -v swiftformat >/dev/null || { echo "ERROR: swiftformat is required" >&2; exit 2; }
xcrun simctl list devices available | grep -q 'iPhone' || {
    echo "ERROR: simulator is unavailable" >&2
    exit 2
}

samples="${PAPERCUP_IOS_HOST_HEALTH_SAMPLES:-3}"
interval="${PAPERCUP_IOS_HOST_HEALTH_INTERVAL_SEC:-1}"
media_limit="${PAPERCUP_IOS_MEDIA_CPU_LIMIT:-25}"
window_server_limit="${PAPERCUP_IOS_WINDOWSERVER_CPU_LIMIT:-80}"
max_media=0
max_window_server=0

sample_cpu() {
    ps -axo pcpu=,command= | awk '
        {
            cpu = $1 + 0
            executable = $2
            sub(/^.*\//, "", executable)
            if (executable == "VTDecoderXPCService" || executable == "WallpaperAerials") {
                media += cpu
            }
            if (executable == "WindowServer") {
                window_server += cpu
            }
        }
        END { printf "%.1f %.1f\n", media, window_server }
    '
}

for ((sample = 1; sample <= samples; sample += 1)); do
    read -r media_cpu window_server_cpu < <(sample_cpu)
    max_media="$(awk -v old="$max_media" -v new="$media_cpu" 'BEGIN { print (new > old ? new : old) }')"
    max_window_server="$(awk -v old="$max_window_server" -v new="$window_server_cpu" 'BEGIN { print (new > old ? new : old) }')"
    if (( sample < samples )); then
        sleep "$interval"
    fi
done

if awk -v value="$max_media" -v limit="$media_limit" 'BEGIN { exit !(value >= limit) }'; then
    echo "ERROR: iOS build host GUI media workers are saturated (${max_media}% CPU; limit ${media_limit}%)." >&2
    echo "Select a static wallpaper, disable the video screensaver, and finish any first-login flow before retrying." >&2
    echo "Matched exact processes: VTDecoderXPCService and WallpaperAerials." >&2
    exit 1
fi

if awk -v value="$max_window_server" -v limit="$window_server_limit" 'BEGIN { exit !(value >= limit) }'; then
    echo "ERROR: iOS build host WindowServer is saturated (${max_window_server}% CPU; limit ${window_server_limit}%)." >&2
    echo "Finish the active GUI/first-login work and retry after WindowServer settles." >&2
    exit 1
fi

echo "✓ iOS build host health: GUI media ${max_media}% CPU, WindowServer ${max_window_server}% CPU"

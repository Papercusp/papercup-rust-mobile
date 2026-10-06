#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Lint every shell script with a pinned, checksum-verified ShellCheck.
#
# The release and signing paths are shell (release-ios.sh, ios-ci-signing.sh,
# ios-signing-secrets.sh, the Android builders) and nothing linted them, so a
# malformed directive comment that silently stopped ShellCheck from checking a
# whole file reached the tree unnoticed (WI-10006930). The build hosts do not
# ship ShellCheck, so `make check` fetches the pinned release itself.
#
# Usage: lint-shell.sh [script.sh ...]   (default: every tracked or untracked,
#        not-ignored *.sh in the repository)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION=0.11.0
CACHE="${PAPERCUP_TOOL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/papercup-mobile}/shellcheck-$VERSION"

# ShellCheck publishes no checksum file; these were taken from the v$VERSION
# release archives on 2026-10-06 and pin them from here on.
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) platform=linux.x86_64; sha256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 ;;
    Linux-aarch64 | Linux-arm64) platform=linux.aarch64; sha256=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588 ;;
    Darwin-x86_64) platform=darwin.x86_64; sha256=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6 ;;
    Darwin-arm64) platform=darwin.aarch64; sha256=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79 ;;
    *) echo "ERROR: no pinned ShellCheck build for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    else
        shasum -a 256 "$1" | awk '{ print $1 }'
    fi
}

binary="$CACHE/$platform/shellcheck"
if [ ! -x "$binary" ]; then
    archive="shellcheck-v$VERSION.$platform.tar.xz"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL --retry 3 -o "$tmp/$archive" \
        "https://github.com/koalaman/shellcheck/releases/download/v$VERSION/$archive" \
        || { echo "ERROR: could not download ShellCheck $VERSION (network?)" >&2; exit 1; }
    actual="$(sha256_of "$tmp/$archive")"
    if [ "$actual" != "$sha256" ]; then
        echo "ERROR: ShellCheck $VERSION $platform checksum mismatch: got $actual, pinned $sha256" >&2
        exit 1
    fi
    tar -xJf "$tmp/$archive" -C "$tmp" "shellcheck-v$VERSION/shellcheck"
    mkdir -p "$(dirname "$binary")"
    mv "$tmp/shellcheck-v$VERSION/shellcheck" "$binary"
    chmod +x "$binary"
fi

if [ "$#" -gt 0 ]; then
    scripts=("$@")
else
    scripts=()
    while IFS= read -r -d '' path; do
        scripts+=("$ROOT/$path")
    done < <(git -C "$ROOT" ls-files -z --cached --others --exclude-standard -- '*.sh')
fi

# An empty file list would lint nothing and still exit 0.
[ "${#scripts[@]}" -gt 0 ] || { echo "ERROR: no shell scripts found to lint" >&2; exit 1; }

"$binary" --format=gcc "${scripts[@]}"
echo "OK: ShellCheck $VERSION found no problems in ${#scripts[@]} script(s)"

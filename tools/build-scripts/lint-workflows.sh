#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Lint GitHub Actions workflows with a pinned, checksum-verified actionlint.
#
# Text-contract tests cannot see GitHub's load-time rules (which contexts an
# expression may use, valid keys, needs/outputs wiring). Such a mistake only
# shows up as a dispatch that never starts. One reached a new workflow
# (WI-10006909: `${{ runner.temp }}` in job-level env), so `make check` runs this
# over every workflow before any push.
#
# Usage: lint-workflows.sh [workflow.yml ...]   (default: .github/workflows/*.y*ml)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION=1.7.12
CACHE="${PAPERCUP_TOOL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/papercup-mobile}/actionlint-$VERSION"

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) platform=linux_amd64; sha256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 ;;
    Linux-aarch64 | Linux-arm64) platform=linux_arm64; sha256=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6 ;;
    Darwin-x86_64) platform=darwin_amd64; sha256=5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644 ;;
    Darwin-arm64) platform=darwin_arm64; sha256=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f ;;
    *) echo "ERROR: no pinned actionlint build for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    else
        shasum -a 256 "$1" | awk '{ print $1 }'
    fi
}

binary="$CACHE/$platform/actionlint"
if [ ! -x "$binary" ]; then
    archive="actionlint_${VERSION}_${platform}.tar.gz"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL --retry 3 -o "$tmp/$archive" \
        "https://github.com/rhysd/actionlint/releases/download/v$VERSION/$archive" \
        || { echo "ERROR: could not download actionlint $VERSION (network?)" >&2; exit 1; }
    actual="$(sha256_of "$tmp/$archive")"
    if [ "$actual" != "$sha256" ]; then
        echo "ERROR: actionlint $VERSION $platform checksum mismatch: got $actual, pinned $sha256" >&2
        exit 1
    fi
    tar -xzf "$tmp/$archive" -C "$tmp" actionlint
    mkdir -p "$(dirname "$binary")"
    mv "$tmp/actionlint" "$binary"
    chmod +x "$binary"
fi

if [ "$#" -gt 0 ]; then
    workflows=("$@")
else
    shopt -s nullglob
    workflows=("$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml)
    shopt -u nullglob
fi
# An empty file list would lint nothing and still exit 0.
[ "${#workflows[@]}" -gt 0 ] || { echo "ERROR: no workflow files found to lint" >&2; exit 1; }

# actionlint's ShellCheck integration is off (-shellcheck=) so the verdict does
# not depend on whether the host happens to have ShellCheck installed.
"$binary" -shellcheck= "${workflows[@]}"
echo "OK: actionlint $VERSION found no problems in ${#workflows[@]} workflow file(s)"

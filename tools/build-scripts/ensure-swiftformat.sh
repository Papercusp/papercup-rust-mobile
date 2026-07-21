#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Preflight: verify `swiftformat` is on PATH, auto-installing via Homebrew
# when it's missing. UniFFI's Swift bindgen does NOT fail when swiftformat
# is absent — it just prints "Unable to auto-format papercup.swift using
# swiftformat: No such file or directory" and ships unformatted bindings,
# so a Mac VM that doesn't happen to have swiftformat provisioned degrades
# silently (WI-4986). Source or run this before any
# `uniffi-bindgen ... --language swift` step so formatting can't silently
# depend on whatever happens to be installed on the build host.
#
# No-op on non-macOS hosts (bindings-swift can be invoked for a plain
# text-codegen check off the Mac VM too; swiftformat only matters for the
# real iOS build, which is macOS-only anyway — see build-ios.sh).
set -euo pipefail

if [ "$(uname)" != "Darwin" ]; then
    exit 0
fi

# Homebrew on PATH (Intel + Apple-silicon prefixes) for non-login/SSH shells.
for _brew in /usr/local/bin/brew /opt/homebrew/bin/brew; do
    [[ -x "$_brew" ]] && eval "$("$_brew" shellenv)" && break
done

if ! command -v swiftformat >/dev/null 2>&1; then
    echo "==> swiftformat not found on PATH; installing via Homebrew" >&2
    if command -v brew >/dev/null 2>&1; then
        brew install swiftformat
    else
        echo "ERROR: swiftformat is missing and Homebrew is unavailable to install it." >&2
        echo "Install swiftformat manually (e.g. 'brew install swiftformat') before generating Swift bindings." >&2
        exit 1
    fi
fi

if ! command -v swiftformat >/dev/null 2>&1; then
    echo "ERROR: swiftformat still isn't on PATH after install — generated Swift bindings would ship unformatted." >&2
    exit 1
fi

echo "==> swiftformat ready: $(swiftformat --version)"

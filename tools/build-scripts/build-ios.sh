#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build papercup-bindings as a static library for iOS (sim + device),
# package as PapercupCore.xcframework, then build the SwiftUI app.
# macOS only.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if [ "$(uname)" != "Darwin" ]; then
    echo "ERROR: build-ios.sh requires macOS." >&2
    exit 1
fi

# Add iOS targets if missing
for t in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    rustup target add "$t" 2>/dev/null || true
done

# Preflight: swiftformat (auto-installs via Homebrew if missing). UniFFI's
# Swift bindgen below silently ships UNFORMATTED bindings when swiftformat
# isn't on PATH instead of failing, so this can't be left to whatever
# happens to be provisioned on the build host (WI-4986).
"$REPO_ROOT/tools/build-scripts/ensure-swiftformat.sh"

echo "==> Building papercup-bindings static lib for iOS (device + sim)"
cargo build --release --target aarch64-apple-ios -p papercup-bindings
cargo build --release --target aarch64-apple-ios-sim -p papercup-bindings
cargo build --release --target x86_64-apple-ios -p papercup-bindings

# Lipo the simulator slices together
mkdir -p target/ios-sim-fat
lipo -create \
    target/aarch64-apple-ios-sim/release/libpapercup.a \
    target/x86_64-apple-ios/release/libpapercup.a \
    -output target/ios-sim-fat/libpapercup.a

echo "==> Generating Swift bindings"
cargo run --quiet --bin uniffi-bindgen -- generate \
    crates/papercup-bindings/src/papercup.udl \
    --language swift \
    --out-dir ios/PapercupCore

# Move the modulemap into a headers/ folder so xcodebuild can find it.
mkdir -p ios/PapercupCore/headers
mv -f ios/PapercupCore/papercupFFI.h ios/PapercupCore/headers/
mv -f ios/PapercupCore/papercupFFI.modulemap ios/PapercupCore/headers/module.modulemap

echo "==> Packaging xcframework"
rm -rf ios/PapercupCore.xcframework
xcodebuild -create-xcframework \
    -library target/aarch64-apple-ios/release/libpapercup.a \
    -headers ios/PapercupCore/headers \
    -library target/ios-sim-fat/libpapercup.a \
    -headers ios/PapercupCore/headers \
    -output ios/PapercupCore.xcframework

echo "==> xcframework at: $REPO_ROOT/ios/PapercupCore.xcframework"
echo "==> Open ios/Papercup.xcodeproj in Xcode to build the app target."

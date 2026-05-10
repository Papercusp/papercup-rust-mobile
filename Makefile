# SPDX-License-Identifier: GPL-3.0-or-later
#
# Top-level entry points. Each target is intentionally small and shells
# out to a build script under `tools/build-scripts/` so logic lives in
# one place.

.PHONY: help build-rust build-android build-ios install-android \
        bindings-kotlin bindings-swift test clean

help:
	@echo "Targets:"
	@echo "  make build-rust         — cargo build the host (off-device) Rust core + cli"
	@echo "  make test               — run all Rust tests"
	@echo "  make bindings-kotlin    — regenerate Kotlin bindings into android/app/src/main/kotlin/uniffi"
	@echo "  make bindings-swift     — regenerate Swift bindings into ios/PapercupCore"
	@echo "  make build-android      — cross-compile Rust core for all Android ABIs + assemble debug APK"
	@echo "  make install-android    — build-android then adb install -r"
	@echo "  make build-ios          — build iOS xcframework + Xcode project (macOS only)"
	@echo "  make clean              — remove all build artifacts"

build-rust:
	cargo build --workspace

test:
	cargo test --workspace

bindings-kotlin:
	cargo run --quiet --bin uniffi-bindgen -- generate \
	    crates/papercup-bindings/src/papercup.udl \
	    --language kotlin \
	    --out-dir android/app/src/main/kotlin

bindings-swift:
	cargo run --quiet --bin uniffi-bindgen -- generate \
	    crates/papercup-bindings/src/papercup.udl \
	    --language swift \
	    --out-dir ios/PapercupCore

build-android: bindings-kotlin
	tools/build-scripts/build-android.sh
	tools/build-scripts/install-and-launch.sh

install-android: build-android
	# build-android already installs + launches on every adb device
	# (physical + emulator) via install-and-launch.sh. Kept as an alias.
	@true

build-ios: bindings-swift
	tools/build-scripts/build-ios.sh

clean:
	cargo clean
	rm -rf android/app/build android/app/src/main/jniLibs
	rm -rf ios/build ios/PapercupCore.xcframework

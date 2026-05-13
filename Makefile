# SPDX-License-Identifier: GPL-3.0-or-later
#
# Top-level entry points. Each target is intentionally small and shells
# out to a build script under `tools/build-scripts/` so logic lives in
# one place.

.PHONY: help build-rust build-android build-ios install-android \
        bindings-kotlin bindings-swift test test-ios test-ios-ui check \
        fmt fmt-check clippy lint-android install-hooks clean tokens

help:
	@echo "Targets:"
	@echo "  make check              — pre-push gate: fmt-check + clippy -D warnings + tests"
	@echo "  make install-hooks      — install git pre-push hook that runs 'make check'"
	@echo "  make lint-android       — run Android lint (auto-uses Android Studio JBR if found)"
	@echo "  make fmt                — cargo fmt --all"
	@echo "  make fmt-check          — cargo fmt --all -- --check (fails on diff)"
	@echo "  make clippy             — cargo clippy --workspace --all-targets -- -D warnings"
	@echo "  make build-rust         — cargo build the host (off-device) Rust core + cli"
	@echo "  make test               — run all Rust tests"
	@echo "  make test-ios           — run iOS XCTest unit suite (requires macOS + Xcode)"
	@echo "  make test-ios-ui        — run iOS XCUITest end-to-end suite (paired flows need PAPERCUP_PAIR_PAYLOAD)"
	@echo "  make bindings-kotlin    — regenerate Kotlin bindings into android/app/src/main/kotlin/uniffi"
	@echo "  make bindings-swift     — regenerate Swift bindings into ios/PapercupCore"
	@echo "  make build-android      — cross-compile Rust core for all Android ABIs + assemble debug APK"
	@echo "  make install-android    — build-android then adb install -r"
	@echo "  make build-ios          — build iOS xcframework + Xcode project (macOS only)"
	@echo "  make install-ios        — build-ios + install + launch on iPhone 16 sim (macOS only)"
	@echo "  make tokens             — regenerate PapercupTokens.{kt,swift} from design-tokens/*.tokens.json"
	@echo "  make clean              — remove all build artifacts"

# Mirror of .github/workflows/ci.yml — run before every push so master
# stays green even with the org's Actions on workflow_dispatch only.
check: fmt-check clippy test

fmt:
	cargo fmt --all

fmt-check:
	cargo fmt --all -- --check

clippy:
	cargo clippy --workspace --all-targets -- -D warnings

install-hooks:
	./tools/install-git-hooks.sh

# Run Android lintDebug — needs JAVA_HOME pointing at JDK 17+ (AGP requirement).
# Falls back to Android Studio's bundled JBR if a system java isn't 17+.
lint-android:
	@if [ -d /snap/android-studio/209/jbr ]; then \
		echo "▶ JAVA_HOME=/snap/android-studio/209/jbr (Android Studio bundled JBR)"; \
		JAVA_HOME=/snap/android-studio/209/jbr android/gradlew -p android :app:lintDebug; \
	else \
		echo "▶ Using ambient java"; \
		android/gradlew -p android :app:lintDebug; \
	fi

build-rust:
	cargo build --workspace

test:
	cargo test --workspace

# Run iOS XCTest. PAPERCUP_IOS_SIM_UDID overrides the default sim;
# unset → first available iPhone 16. Splits build + test to dodge
# the Xcode 16.2 destination-resolver race. Real shell logic in
# tools/run-ios-tests.sh because make's $ escaping kept eating the
# variable name.
test-ios:
	./tools/run-ios-tests.sh

# Run iOS XCUITest end-to-end UI tests. Set PAPERCUP_PAIR_PAYLOAD to
# a freshly minted pair JSON to exercise the paste-pair flow + the
# paired-state navigation; without it only the fresh-launch smoke
# test runs (paired flows XCTSkip).
test-ios-ui:
	./tools/run-ios-uitests.sh

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

tokens:
	@command -v node >/dev/null || { echo "node required for design-token codegen"; exit 1; }
	@test -d node_modules/style-dictionary || npm install --silent
	npm run tokens

build-android: tokens bindings-kotlin
	tools/build-scripts/build-android.sh
	tools/build-scripts/install-and-launch.sh

install-android: build-android
	# build-android already installs + launches on every adb device
	# (physical + emulator) via install-and-launch.sh. Kept as an alias.
	@true

build-ios: tokens bindings-swift
	tools/build-scripts/build-ios.sh

install-ios: build-ios
	tools/build-scripts/install-ios.sh

clean:
	cargo clean
	rm -rf android/app/build android/app/src/main/jniLibs
	rm -rf ios/build ios/PapercupCore.xcframework

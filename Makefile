# SPDX-License-Identifier: GPL-3.0-or-later
#
# Top-level entry points. Each target is intentionally small and shells
# out to a build script under `tools/build-scripts/` so logic lives in
# one place.

.PHONY: help build-rust build-android build-ios install-android \
        bindings-kotlin bindings-swift test test-ios test-ios-ui \
        verify-ios-release test-ios-release release-ios check \
        fmt fmt-check clippy lint-android test-android-java test-android-release-provenance \
        test-ios-host-health install-hooks clean tokens tokens-check

help:
	@echo "Targets:"
	@echo "  make check              — pre-push gate: fmt-check + clippy -D warnings + tests"
	@echo "  make install-hooks      — install git pre-push hook that runs 'make check'"
	@echo "  make lint-android       — run Android lint (resolves Java 17+ from JAVA_HOME/JBR)"
	@echo "  make test-android-java  — test the dynamic Android Java resolver"
	@echo "  make test-android-release-provenance — test Android release source/version/hash binding"
	@echo "  make fmt                — cargo fmt --all"
	@echo "  make fmt-check          — cargo fmt --all -- --check (fails on diff)"
	@echo "  make clippy             — cargo clippy --workspace --all-targets -- -D warnings"
	@echo "  make build-rust         — cargo build the host (off-device) Rust core + cli"
	@echo "  make test               — run all Rust tests"
	@echo "  make test-ios           — run iOS XCTest unit suite (requires macOS + Xcode)"
	@echo "  make test-ios-ui        — run iOS XCUITest end-to-end suite (paired flows need PAPERCUP_PAIR_PAYLOAD)"
	@echo "  make verify-ios-release — validate iOS metadata, privacy, signing config, and release copy"
	@echo "  make test-ios-release   — exercise the iOS release verifier and its failure guards"
	@echo "  make test-ios-host-health — test the macOS GUI/media saturation preflight"
	@echo "  make release-ios        — archive/export iOS 1.0.0 (set signing env; ACTION=preflight|archive|export|validate|upload)"
	@echo "  make bindings-kotlin    — regenerate Kotlin bindings into android/app/src/main/kotlin/uniffi"
	@echo "  make bindings-swift     — regenerate Swift bindings into ios/PapercupCore"
	@echo "  make build-android      — cross-compile Rust core for all Android ABIs + assemble debug APK"
	@echo "  make install-android    — build-android then adb install -r"
	@echo "  make build-ios          — build iOS xcframework + Xcode project (macOS only)"
	@echo "  make install-ios        — build-ios + install + launch on iPhone 16 sim (macOS only)"
	@echo "  make tokens             — regenerate PapercupTokens.{kt,swift} from design-tokens/*.tokens.json"
	@echo "  make tokens-check       — regen tokens then fail if anything changed (drift guard; part of 'make check')"
	@echo "  make clean              — remove all build artifacts"

# Mirror of .github/workflows/ci.yml — run before every push so master
# stays green even with the org's Actions on workflow_dispatch only.
check: fmt-check clippy test tokens-check test-android-release-provenance test-ios-host-health

# Regenerate design-token outputs and fail if the working tree differs.
# Catches the drift case where someone edits *.tokens.json but forgets
# `make tokens`. Auto-installs node deps if missing.
tokens-check:
	@command -v node >/dev/null || { echo "node required for tokens-check"; exit 1; }
	@test -d node_modules/style-dictionary || npm install --silent
	@$(MAKE) -s tokens
	@if ! git diff --quiet \
	    design-tokens/primitives.tokens.json \
	    android/app/src/main/kotlin/com/papercuspai/operator/mobile/theme/PapercupTokens.kt \
	    ios/Papercup/Sources/Papercup/PapercupTokens.swift; then \
	    echo "✗ design-token outputs drifted from sources. Run 'make tokens' and commit the diff."; \
	    git --no-pager diff --stat \
	        design-tokens/primitives.tokens.json \
	        android/app/src/main/kotlin/com/papercuspai/operator/mobile/theme/PapercupTokens.kt \
	        ios/Papercup/Sources/Papercup/PapercupTokens.swift; \
	    exit 1; \
	fi
	@echo "✓ design tokens in sync"

fmt:
	cargo fmt --all

fmt-check:
	cargo fmt --all -- --check

clippy:
	cargo clippy --workspace --all-targets -- -D warnings

install-hooks:
	./tools/install-git-hooks.sh

# Run Android lintDebug — resolve Java 17+ dynamically so Snap revision changes
# cannot strand the gate on a deleted Android Studio JBR path.
lint-android:
	@set -e; \
	JAVA_HOME="$$(tools/build-scripts/resolve-java-home.sh)"; \
	export JAVA_HOME; \
	echo "▶ JAVA_HOME=$$JAVA_HOME (validated Java 17+)"; \
	android/gradlew -p android :app:lintDebug

test-android-java:
	./tools/tests/resolve-java-home-test.sh

test-android-release-provenance:
	./tools/tests/android-release-provenance-test.sh

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

verify-ios-release:
	./tools/build-scripts/verify-ios-release.sh

test-ios-release:
	./tools/tests/verify-ios-release-test.sh

test-ios-host-health:
	./tools/tests/ios-build-host-health-test.sh

release-ios:
	./tools/build-scripts/release-ios.sh $(or $(ACTION),export)

bindings-kotlin:
	cargo run --quiet --bin uniffi-bindgen -- generate \
	    crates/papercup-bindings/src/papercup.udl \
	    --language kotlin \
	    --out-dir android/app/src/main/kotlin

bindings-swift:
	tools/build-scripts/check-ios-build-host-health.sh
	# swiftformat preflight (auto-installs on macOS, no-op elsewhere): the
	# uniffi-bindgen generate below silently ships unformatted Swift when
	# swiftformat isn't on PATH instead of failing (WI-4986).
	tools/build-scripts/ensure-swiftformat.sh
	cargo run --quiet --bin uniffi-bindgen -- generate \
	    crates/papercup-bindings/src/papercup.udl \
	    --language swift \
	    --out-dir ios/PapercupCore

tokens:
	@command -v node >/dev/null || { echo "node required for design-token codegen"; exit 1; }
	@test -d node_modules/style-dictionary || npm install --silent
	npm run tokens

build-android: tokens bindings-kotlin
	JAVA_HOME="$$(tools/build-scripts/resolve-java-home.sh)" tools/build-scripts/build-android.sh
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

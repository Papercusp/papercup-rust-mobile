<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Build

Top-level `Makefile` drives everything. The Rust workspace is the source of
truth; native projects consume generated bindings + the cross-compiled core.

> **Runtime target = TypeScript / Hono.** Mobile pair JSON must point at the
> Hono operator (production `https://api.papercupai.com`; local Android
> emulator `http://10.0.2.2:3055`; local iOS sim `http://localhost:3055`).
> `:3060` is the Rust dev server — do not paste it into pair JSON.

## Prerequisites

### Host (off-device, Linux or macOS)

- Rust stable + `cargo`
- `make`

### Android

- Java 17 (`JAVA_HOME=…/jdk17`)
- Android SDK platform 36 + NDK (defaults to `~/Android/Sdk/ndk/27.0.12077973`; override with `ANDROID_NDK_HOME`)
- `cargo install cargo-ndk`
- `rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android`

### iOS (macOS only)

- Xcode 16.2+ (16.3 recommended — resolves the destination-resolver race that breaks `xcodebuild test -scheme`)
- iOS Simulator runtime 18.x
- `brew install xcodegen` (Mac VM has it at `/usr/local/bin/xcodegen` — Intel brew location)
- `rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios`

## Make targets

| Target | What it does |
|---|---|
| `make check` | fmt-check + clippy `-D warnings` + cargo test workspace. **Local pre-push gate.** |
| `make test` | cargo test workspace (44 tests). |
| `make build-rust` | cargo build workspace. |
| `make build-android` | cargo-ndk cross-compile → assembleDebug APK at `android/app/build/outputs/apk/debug/app-debug.apk` (~79 MB). |
| `tools/build-scripts/build-android.sh release` | Verified UniFFI cross-compile → signed release APK + AAB (when release signing properties are present). |
| `make install-android` | assembleDebug + `adb install -r`. |
| `make build-ios` | iOS cross-compile → `ios/PapercupCore.xcframework` (3 slices: arm64-device, arm64-sim, x86_64-sim). |
| `make test-ios` | Build for testing + test-without-building on iPhone 16 sim. Flaky post-Sentry; retries 8x with 5s backoff. Needs `PAPERCUP_IOS_SIM_UDID=<udid>` env. |
| `make test-ios-ui` | XCUITest variant. |
| `make lint-android` | Android Studio lint. |
| `make install-hooks` | Installs `.git/hooks/pre-push` that runs `make check`. Bypass with `git push --no-verify`. |
| `make fmt` / `make fmt-check` / `make clippy` | Granular gates. |

## Build secrets (NOT committed)

| Secret | Location | Used by |
|---|---|---|
| `google-services.json` | `android/app/google-services.json` | Phase 7 FCM. Crashlytics no-op without it. |
| Picovoice AccessKey | `android/app/picovoice.access-key` + Swift `PICOVOICE_ACCESS_KEY` in `Info.plist` | Phase 5 wake-word. Dormant without it. |
| `hey-papercup.ppn` | `android/app/src/main/assets/hey-papercup.ppn` + iOS `Resources/hey-papercup.ppn` | Picovoice keyword model. Falls back to `BuiltInKeyword.JARVIS` if absent. |
| Apple signing identity + provisioning profile | `~/Library/MobileDevice/Provisioning Profiles/` | Phase 10 store submission. |
| Sentry DSN | iOS `Info.plist:SENTRY_DSN` | No-op without DSN. |
| FCM service-account JSON | server-side, `~/.papercusp/fcm-service-account.json` | Backend agent territory. |
| Android release keystore | `~/.papercusp/secrets/papercup-android-release.keystore`; credentials in `~/.gradle/gradle.properties` (`PAPERCUP_RELEASE_KEYSTORE`, `PAPERCUP_RELEASE_KEYSTORE_PASSWORD`, `PAPERCUP_RELEASE_KEY_ALIAS`, optional `PAPERCUP_RELEASE_KEY_PASSWORD`) | Release APK/AAB signing (`signingConfigs` in `app/build.gradle.kts`). An absent or blank key password uses the keystore password. Release assembly/bundling rejects missing required inputs or a missing keystore; debug/host checks do not require signing. Generated 2026-07-16, RSA-4096, cert SHA-256 `efeb65c4…912b93`. ⚠ Back this keystore up — losing it means new installs can't update existing ones outside Play App Signing. |

Templates exist at `android/app/secrets-template/google-services.json.example`.

## Common workflows

Public release builds target API 36, reject non-HTTPS pairing endpoints, and
disable platform cleartext traffic. Debug builds permit cleartext only for the
explicit emulator/loopback endpoints enforced by `EndpointSecurity`.

### Run the Android app on emulator/device

```sh
make install-android
adb shell am start -n com.papercuspai.operator.mobile.debug/com.papercuspai.operator.mobile.MainActivity
```

### Run the iOS app on simulator (Mac only)

```sh
make build-ios
# from Mac:
cd ios && xcodegen && xcodebuild -project Papercup.xcodeproj -scheme Papercup \
  -destination "platform=iOS Simulator,id=$PAPERCUP_IOS_SIM_UDID" build
xcrun simctl install $PAPERCUP_IOS_SIM_UDID build/Build/Products/Debug-iphonesimulator/Papercup.app
xcrun simctl launch $PAPERCUP_IOS_SIM_UDID com.papercuspai.operator.mobile
```

### Iterate on Rust core only

Run the maintained device API smoke against the supported current-build operator:

```sh
PAPERCUP_LIVE_BASE=http://127.0.0.1:3170 bash tools/run-android-checks.sh live
```

This mode verifies the current workspace selection, creates an empty private
second workspace, mints a fresh pairing, and runs the canonical Cargo smoke
with that explicit second scope. It revokes its pairing and removes only its
own fixture on success or failure, preserving the desktop selection. It also
retains the command, source fingerprints, executed result and cleanup evidence
under `android/app/build/ci-evidence`. Only loopback operators are accepted;
the containing runtime must be measured before invocation. API proof does not
establish native, signed-candidate, physical-phone or Play acceptance.

To run the maintained paired Inbox native journey against a prepared operator
bundle with its own migrated database, workspace, HOME and embedding sidecar:

```sh
ANDROID_SERIAL=emulator-5556 bash tools/run-android-checks.sh isolated-native \
  /path/to/prepared/operator-checkout android/app/build/ci-evidence/paired-attempt
```

This extends `with-test-pg.mjs --isolated-runtime=operator-api`. It starts the
actual Hono bundle, checks its private workspace before minting a one-use token,
and runs pairing/JNI, Inbox scope/rendering, invalid-JWT handling, recovery and
navigation on the explicitly owned API 36 / 16 KB emulator. The native runner
revokes its device and removes its workspace and private app inputs; the wrapper
stops its host even on interruption, then the canonical bootstrap disposes its
database and private runtime. Runtime and native evidence use separate attempt
directories. Prepare the operator dependencies/bundle before invocation; a
missing bundle or an ambient runtime is refused. Scheduled CI still needs this
prepared counterpart wired into its job before it establishes automatic paired
coverage. This debug integration route preserves the signed-candidate, physical
phone, external mesh and Play acceptance requirements.

```sh
cargo watch -x 'test --workspace'
```

UDL changes require re-running the binding generator (see `tools/build-scripts/`); for iOS this means regenerating + rebuilding the xcframework before the Swift code sees new symbols.

## Known issues

- **Xcode 16.2 destination race**: `xcodebuild` occasionally fails first-try with "iOS 18.2 is not installed" because the SDK and the only-installed 18.3.1 runtime mismatch on the destination resolver. The `make test-ios` wrapper retries 8x. Switching to Xcode 16.3 resolves it.
- **iOS voice mode requires Xcode 16.3+**. ElevenLabsSDK pulls LiveKit + livekit-uniffi-xcframework + JWTKit transitively. Xcode 16.2's SwiftPM dep-order resolution fails to build these in the right order, surfacing as `no such module 'LiveKitUniFFI'` and then `no such module 'Crypto'`. Same dep-resolution fragility as the destination-resolver race above. Android voice path is unaffected (Maven Central + Gradle handles deps cleanly).
- **`xcodebuild test -scheme` post-Sentry**: Permanently broken since the Sentry SwiftPM landed — the package resolver loses sim devices in Xcode's cache. Workaround: per-target builds (`xcodebuild -target Papercup`, `-target PapercupTests`, `-target PapercupUITests`).
- **CI triggers**: Android verification has push/PR coverage and a scheduled route for managed `[skip ci]` commits. Read the actual run event, source SHA, executed tests and retained artifact before claiming automatic coverage; a cached or historical result does not prove a new paired journey.
- **Apple Developer Program**: Required for APNs delivery, NetworkExtension entitlement (mesh), and TestFlight. iOS push + mesh code is wired but inert without enrollment.

## Hardware verified

- Android: Samsung Fold5 `RFCW80RTBGJ` (intermittently drops off `adb`), x86_64 emulator AVD `papercusp-test`.
- iOS: iPhone 16 simulator UDID `428F2FFE-9921-470D-9D46-E23563CE02CA` inside macOS Sonoma 14.8.5 QEMU/OSX-KVM VM (Threadripper Linux host).

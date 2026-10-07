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

For headless emulator checks, use `-gpu swiftshader -feature
GLDirectMem,HasSharedSlotsHostMemoryAllocator`. API 36.1's Goldfish mapper
requires the DMA color-buffer readback extension; choosing a renderer alone
does not supply it. The maintained `verify-emulator-boot` phase checks that
extension on API 36.1+, stable framework services, and at least 512 MiB free
inside `/data` before installing test fixtures. Host AVD-space preflight and
the boot-completed property do not establish guest readiness. If an existing
AVD fails guest-space admission, create an owned temporary AVD with fresh
userdata; preserve the original SDK and AVD rather than wiping them.

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
directories. The isolated invocation runs the maintained runner controls and
Rust biometric gate tests before the native build. Its revocation journey
checks that missing and denied biometric callbacks leave the device valid,
then uses an explicitly recorded test approval callback to exercise actual
JNI/HTTP revocation and fresh pairing. This does not verify OS biometric UI or
physical hardware. Prepare the operator dependencies/bundle before invocation; a
missing bundle or an ambient runtime is refused. Independent Android CI consumes
a prepared operator checkout, records its exact commit, and validates the bundle
freshness before and after execution. Prepare that counterpart with the maintained
dependency/bundle builders; Android CI does not require GitHub Actions secrets.

The automatic emulator leg runs this paired route. Its cache key includes both
mobile content and the pinned operator commit; restored proof is revalidated.
Only successful exact-source, APK, selected-test JUnit, journey and cleanup evidence
can become a success cache. The artifact retains counterpart provenance and
paired diagnostics, without uploading the operator checkout or dependency tree.
The native selection also runs the maintained chat 401/403 Compose/JNI
regressions against HTTP fixtures, checking draft retention, absence of unsent
conversation bubbles, explicit retry and persisted-thread reconciliation.
It also exercises the actual shell's Settings roundtrip and manual re-pair,
activity recreation, and different-workspace/server draft isolation. Drafts
survive same-scope recovery in shell saved state, never auto-send, and are
discarded when the server or workspace changes; no credentials enter that state.

Keep raw attempt receipts private and unchanged. Before committing a public
operational summary under the operator's `docs/evidence`, use its maintained
identity-safe JSON exporter from that checkout:

```sh
node scripts/lib/identity-leak-patterns.mjs --serialize-json \
  < "$PRIVATE_SUMMARY_JSON" > "$PUBLIC_SUMMARY_JSON"
```

Use distinct input and output files. The exporter sanitizes personal home paths
and machine identities in string values while preserving counts, source/APK/log
hashes and scope limits. It rejects invalid JSON or identity-bearing field names
without emitting a partial report. When a command argument represents a prepared
operator checkout, record a portable environment-variable reference and explain
its exact source-commit basis. Retain the original command privately, bind the
hash of the committed public bytes, and do not claim hosted, release-candidate,
physical-phone or Play acceptance from a local debug run.
An actual independent executor run must pass before claiming automatic paired coverage.
This debug integration route preserves the signed-candidate, physical
phone, external mesh and Play acceptance requirements.

```sh
cargo watch -x 'test --workspace'
```

UDL changes require re-running the binding generator (see `tools/build-scripts/`); for iOS this means regenerating + rebuilding the xcframework before the Swift code sees new symbols.

## Release publication gate

`build-android.sh release` refuses to build a candidate unless the standing
checks have passed on the exact clean commit being released:

```sh
bash tools/run-android-checks.sh host        # host gate
bash tools/run-android-checks.sh connected   # API 36 / 16 KB device gate
bash tools/build-scripts/build-android.sh release
```

Each check phase captures `HEAD` when it starts (or `dirty` if the tree is not
clean). After its results verify, the runner calls
`android-release-provenance.sh checks-pass <host|connected> <start-commit|dirty>`.
That writes `android/app/build/outputs/papercusp-android-checks/<phase>.json`, but
only if the tree was clean at both start and end and `HEAD` did not move. A
failed, partial, dirty or moved-source run writes no pass record.

The release path calls `android-release-provenance.sh checks-gate` before Gradle
assembles anything. `write` then refuses (`ERROR: publication gate: ...`) unless
both the host and connected records match the clean `HEAD`, and it embeds them
in the provenance manifest as `checks`. `verify` re-validates those embedded
records against the commit, so a manifest with a dropped, rebound or failed
phase does not verify. Records are local build output: a hosted CI pass does
not satisfy a local release build, and any new commit (including a git-sync
sweep) requires both phases to run again. `tools/tests/android-release-provenance-test.sh`
covers each refusal.

### Automatic Android CI

Android verification runs independently of GitHub Actions. The local user service
`papercusp-android-ci.service` invokes `python3 tools/android-ci.py`; its timer
checks every 30 minutes after the preceding invocation finishes, including managed
`[skip ci]` commits. The executor holds an exclusive lock and owns a fresh API 36 /
16-KB emulator. `ANDROID_SERIAL` scopes installation and instrumentation to that
device; other fleet devices are untouched.

The executor reuses `check-android-host`, design-token drift verification,
`run-android-checks.sh connected`, the canonical isolated operator/JNI feature
journey, and `verify-isolated-native`. Supply a prepared operator checkout through
`PAPERCUP_OPERATOR_DIR` in external configuration
`~/.config/papercusp/android-ci.env`; the default is the maintained
`papercusp-staging.current` prepared generation. The executor resolves and pins
that generation under the existing staging GC lock before re-exec. Its exact
commit and bundle freshness must verify before
expensive checks. The paired journey uses a private migrated operator runtime.
Toolchain, SDK image, emulator loader, disk and KVM preflight failures retain
a failed receipt.

Install the maintained units and run them without a GitHub account:

```sh
systemctl --user link "$PWD/tools/ci/papercusp-android-ci.service" "$PWD/tools/ci/papercusp-android-ci.timer"
systemctl --user daemon-reload
systemctl --user enable --now papercusp-android-ci.timer
systemctl --user start papercusp-android-ci.service
make check-android-ci
python3 tools/android-ci.py --force
```

Results, logs, tested APKs, JUnit, lint and paired-runtime evidence live under
`~/.local/state/papercusp/android-ci/attempts/`; `latest.json` identifies the current
verdict. Success reuse requires the exact mobile source, counterpart, current week
and retained artifact hashes, followed by paired-proof revalidation. Source or
counterpart changes during execution and failing gates revoke admission. There is
no upload or publication step. The existing candidate publication gate additionally
requires the executor's clean-source `ci` pass, written only after paired proof
verification; a failed or interrupted replacement run removes that admission.
Signed-candidate, physical-phone and Play acceptance
remain separate release requirements.

The remaining `ci.yml` and `testflight.yml` workflows are iPhone-only. Android's
shared Rust, Kotlin bindings and design-token checks execute on the local route.

### TestFlight (signed iPhone builds)

`.github/workflows/testflight.yml` builds a signed App Store IPA on the macOS 26
runner and uploads it to App Store Connect, where it appears in TestFlight. It is
dispatch only, because every run uses up a build number:

```sh
gh workflow run testflight.yml -R Papercusp/papercup-rust-mobile            # build number = run number
gh workflow run testflight.yml -R Papercusp/papercup-rust-mobile \
  -f build_number=42 -f upload=false                                         # signed export only
```

Its first step, `ios-ci-signing.sh require-secrets`, runs before any toolchain
setup. It prints `MISSING_SECRET: <name>` for every absent repository secret and
rejects a malformed team ID or non-base64 file:

| Repository secret | Contents |
|---|---|
| `APPLE_TEAM_ID` | 10-character Apple Developer team ID |
| `IOS_DIST_CERT_P12_BASE64` | base64 of the Apple Distribution certificate + private key (`.p12`) |
| `IOS_DIST_CERT_PASSWORD` | password of that `.p12` |
| `IOS_APPSTORE_PROFILE_BASE64` | base64 of the App Store provisioning profile for `com.papercuspai.operator.mobile` (Push Notifications enabled) |
| `ASC_API_KEY_ID` | App Store Connect API key ID |
| `ASC_API_ISSUER_ID` | App Store Connect issuer ID |
| `ASC_API_KEY_P8_BASE64` | base64 of that key's `AuthKey_<id>.p8` |

Only three things need the owner's Apple login: Apple Developer Program
membership, the App Store Connect app record for
`com.papercuspai.operator.mobile` (Apple's API cannot create apps), and one App
Store Connect API key with the Admin role. Save the key as
`~/.papercusp/secrets/apple/asc/AuthKey_<KEY ID>.p8` and put the Issuer ID in
`notes.txt` there. Everything else comes from that key:

```sh
python3 tools/build-scripts/ios-asc-provision.py plan    # read-only: EXISTS / CREATE lines
python3 tools/build-scripts/ios-asc-provision.py apply   # bundle ID + Push, Apple Distribution
                                                         # cert for dist.csr, App Store profile
bash tools/build-scripts/ios-signing-secrets.sh plan     # then apply: sets the 7 secrets above
```

`apply` writes `dist.cer` and `appstore.mobileprovision` into the folder and is
safe to re-run. It exits 3 with `WAITING_FOR` while the app record is missing.
`make test-ios-signing` runs it against a stub API that verifies every ES256
token.

`ios-ci-signing.sh install` then refuses a profile that names another team or
app, lists devices, allows debugging, lacks production push, has expired, or
does not contain the imported certificate. It imports the identity into a
temporary keychain under `$RUNNER_TEMP`, and `cleanup` (an `always()` step)
deletes it. `release-ios.sh` signs manually in this mode
(`PAPERCUP_SIGNING_STYLE=manual`). The profile reaches only the app target, via
`PAPERCUP_APP_PROVISIONING_PROFILE` in `ios/project.yml`. Local
`make release-ios` keeps automatic signing through the Mac's Xcode account.
`make test-ios-signing` covers all of this with fixtures.

## Known issues

- **Xcode 16.2 destination race**: `xcodebuild` occasionally fails first-try with "iOS 18.2 is not installed" because the SDK and the only-installed 18.3.1 runtime mismatch on the destination resolver. The `make test-ios` wrapper retries 8x. Switching to Xcode 16.3 resolves it.
- **iOS voice mode requires Xcode 16.3+**. ElevenLabsSDK pulls LiveKit + livekit-uniffi-xcframework + JWTKit transitively. Xcode 16.2's SwiftPM dep-order resolution fails to build these in the right order, surfacing as `no such module 'LiveKitUniFFI'` and then `no such module 'Crypto'`. Same dep-resolution fragility as the destination-resolver race above. Android voice path is unaffected (Maven Central + Gradle handles deps cleanly).
- **`xcodebuild test -scheme` post-Sentry**: Permanently broken since the Sentry SwiftPM landed — the package resolver loses sim devices in Xcode's cache. Workaround: per-target builds (`xcodebuild -target Papercup`, `-target PapercupTests`, `-target PapercupUITests`).
- **CI triggers**: The independent Android timer observes managed `[skip ci]` commits. Read `latest.json`, source identities, executed tests and retained artifacts before claiming coverage; revalidated cached proof is not a new journey.
- **Apple Developer Program**: Required for APNs delivery, NetworkExtension entitlement (mesh), and TestFlight. iOS push + mesh code is wired but inert without enrollment.

## Hardware verified

- Android: Samsung Fold5 `RFCW80RTBGJ` (intermittently drops off `adb`), x86_64 emulator AVD `papercusp-test`.
- iOS: iPhone 16 simulator UDID `428F2FFE-9921-470D-9D46-E23563CE02CA` inside macOS Sonoma 14.8.5 QEMU/OSX-KVM VM (Threadripper Linux host).

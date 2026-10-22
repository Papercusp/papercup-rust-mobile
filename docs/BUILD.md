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

- Simulator checks: Xcode 16.3+, iPhoneSimulator SDK17+ and an available iOS17+ iPhone runtime.
- Current release checks: Xcode26+, iPhoneOS SDK26+ and an available iOS26+ iPhone runtime.
- The selected Xcode must support the actual host macOS; check Apple's [SDK and system requirements](https://developer.apple.com/xcode/system-requirements/).
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
make check-android-ci                      # host, API36/16KB native and paired CI gate
bash tools/build-scripts/build-android.sh release
```

Each check phase captures `HEAD` when it starts (or `dirty` if the tree is not
clean). After its results verify, the runner calls
`android-release-provenance.sh checks-pass <host|connected|ci> <start-commit|dirty>`.
That writes `android/app/build/outputs/papercusp-android-checks/<phase>.json`, but
only if the tree was clean at both start and end and `HEAD` did not move. A
failed, partial, dirty or moved-source run writes no pass record.

The release path calls `android-release-provenance.sh checks-gate` before Gradle
assembles anything. `write` then refuses (`ERROR: publication gate: ...`) unless
the host, connected and independent CI records match the clean `HEAD`, and it embeds them
in the provenance manifest as `checks`. `verify` re-validates those embedded
records against the commit, so a manifest with a dropped, rebound or failed
phase does not verify. Records are local build output: any new commit (including
a git-sync sweep) requires the complete independent gate to run again.
`tools/tests/android-release-provenance-test.sh`
covers each refusal.

### Automatic Android CI

Android verification runs independently of GitHub Actions. The local user service
`papercusp-android-ci.service` invokes `python3 tools/android-ci.py`; its timer
checks every 30 minutes after the preceding invocation finishes, including managed
`[skip ci]` commits. The executor holds an exclusive lock and owns a fresh API 36 /
16-KB emulator. `ANDROID_SERIAL` scopes installation and instrumentation to that
device; other fleet devices are untouched.

The maintained debug/release builder, complete native/check journey and cloud
native runner share the same `android-ci/executor.lock`. A competing writer
refuses before modifying outputs; nested commands verify their inherited
descriptor or the exact held descriptor of their live ancestor. A different
emulator does not provide independent custody of the shared build directory.
For a multi-step producer, hold custody across build, capture and verification:

```sh
python3 tools/android-ci.py --exclusive-command bash -c 'bash tools/build-scripts/build-android.sh release && bash tools/build-scripts/android-release-provenance.sh verify "$PAPERCUP_RELEASE_VERSION"'
```

Supply the existing required release version/signing configuration before that
command. The executor disables persistent Gradle daemons for its leased command;
the lease ends when the producer exits. Before a release handoff, complete the
current CI invocation, verify its clean-source receipt, and agree a bounded
producer interval. The timer may be held during that interval and resumed after
the producer has verified and retained its candidate. Never bypass executor
custody or consume mutable shared outputs while another writer owns it.

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

### Native iPhone checks and TestFlight delivery

GitHub Actions is disabled and the mobile workflow files are retired. Shared Rust,
UniFFI and design-token checks remain in the independent Android executor. iPhone
execution uses `tools/ios-ci.py` on a native Mac with Python3.9+, Node22+,
xcodegen and the pinned Rust toolchain. The default `--mode simulator` accepts
Xcode16.3+, iPhoneSimulator SDK17+ and an available iOS17+ iPhone simulator.
It works with the maintained Mac VM's Xcode16.4 / SDK18.5 / iOS18.6 runtime;
Apple credentials and physical hardware are not prerequisites for this mode.
Select a side-by-side Xcode with `DEVELOPER_DIR` and optionally pin a device
with `PAPERCUP_IOS_SIM_UDID`. Without a pin the newest available supported
iPhone runtime is selected. The runner preserves the global Xcode selection.

```sh
python3 tools/ios-ci.py --preflight           # simulator admission; no test pass
make check-ios-ci                          # simulator build, unit and smoke UI
python3 tools/ios-ci.py --mode simulator --force
make test-ios-ci test-ios-release test-ios-signing test-rust-toolchain-pin
# Separate public-release toolchain/archive verification:
python3 tools/ios-ci.py --mode check --preflight
python3 tools/ios-ci.py --mode check --force
```

Simulator mode reuses the Android source/submodule fingerprint and bounded phase
logger, then runs the static release contract, pinned Rust setup, existing native
build/unit/result guards, exactly five backend-free UI tests and screenshot export.
The controlled relay tests cover cloud and transport outage recovery plus HTTP
401/403 re-pair guidance and Keychain clearing across ordinary relaunch. They
verify native client behavior; real token expiry/revocation, workspace isolation
and LAN/public HTTPS routing still require the private/live integration journeys.
It does not build a device archive, export an IPA or emit a candidate manifest.
Explicit `--mode check` adds the SDK26 unsigned device archive and archive
validation; both check and signed modes still require Xcode26+, iPhoneOS SDK26+
and an available iOS26+ iPhone simulator (Intel hosts need the universal runtime).

#### Preparing the current-SDK toolchain on the shared Mac VM

Read the current registered Mac lease before any guest installation, restart or
simulator changes. The P-008 executor must finish its native run, restore and
read back provider configuration, clean its owned fixture and explicitly release
the lease before the toolchain lane acquires it. A successful older simulator
run is retained evidence for those cases, not a current-SDK candidate.

Measure `sw_vers`, `uname -m`, `xcode-select -p`, `xcodebuild -version` and both
`xcrun --sdk iphoneos --show-sdk-version` and
`xcrun --sdk iphonesimulator --show-sdk-version`. Inspect installed Xcode apps
and available iPhone runtimes before deciding an OS upgrade is needed. The
runner records measured macOS version, architecture and Darwin release in
`result.json`'s `toolchain.host`; changed host identity prevents cached success
reuse even when the Xcode version is unchanged.

Apple's [upload minimum](https://developer.apple.com/news/upcoming-requirements/?id=04282026a)
is Xcode26+/SDK26+, not a requirement to install the newest Xcode27 release.
Choose a stable accepted Xcode whose documented host range includes the
measured guest. For example, Apple's system table checked on 2026-10-22 lists
Xcode26.6 with SDK26.5 on macOS26.2–26.x, and Xcode26.3 on macOS15.6–26.x.
These are compatibility examples, not proof of installation or a higher minimum.

Keep the existing Xcode app and simulator evidence intact. Install an authorized
Apple toolchain beside it, then set `DEVELOPER_DIR` to that app's actual
`Contents/Developer` directory for this process. Do not change the global
`xcode-select` selection. Legal agreement acceptance, account login and paid
downloads remain separate authorization gates. Take a snapshot with a verified
restore route before any destructive guest OS change; do not upgrade a guest
that already meets the selected toolchain's host requirements.

After the coordinated install, select an available iOS26+ iPhone UDID from
`xcrun simctl list devices available -j`, set `PAPERCUP_IOS_SIM_UDID`, and use
the maintained runner in the same exact-source checkout:

```sh
python3 tools/ios-ci.py --mode check --preflight
python3 tools/ios-ci.py --mode check --force
```

Preflight must pass before the full matrix. Retain the clean source commit and
fingerprint, selected developer directory, host/toolchain/runtime identity,
executed unit and UI summaries, screenshot inventory and SDK26 archive facts.
Use a fresh private payload for each required paired journey; the generic smoke
does not replace P-008. Unsigned check mode emits archive facts only; an
installable manual IPA still requires the separately authorized signing route
below and the existing signed candidate manifest.

An exclusive native executor lock prevents overlap. Logs, XCTest bundles, summaries,
screenshots, optional archive and SHA256 inventory are retained under
`~/.local/state/papercusp/ios-ci/attempts/`; `latest.json` is the verdict.
Before the unit build, the runner verifies DerivedData's absolute checkout and
Xcode/SDK identity. Copied, unmarked or changed-toolchain caches lose compiled
state while retaining SwiftPM downloads; `derived-data.json` records the reset.
Matching ownership preserves incremental builds. Prior retained test attempts
are separate from this build cache and remain intact.
`--preflight` does not establish a passing test result. Changed source prevents
test admission or upload. Daily success reuse requires the same source, toolchain,
mode and hash-verified artifacts. Simulator and archive-check proofs have separate
`success-simulator.json` and `success.json` pointers; one cannot satisfy the other.
A failed replacement revokes that mode's proof. Paired UI requires
`--paired-ui --pair-payload-file /private/fresh-payload.json` and is never cached.
The payload must be owner-only, outside the repository and sanitized for screenshots.
For actual uninstall/reinstall acceptance, use simulator mode with
`--reinstall-ui --pair-payload-file /private/fresh-payload.json` instead of
`--paired-ui`. The owned disposable loopback operator must stay available through
all three native test phases. The runner pairs, proves an authorized ordinary
relaunch without reusing the token, then uses `simctl uninstall` and `simctl install`.
It requires the old data container to disappear and a different container to be
created, then verifies onboarding on two launches without any credential-wipe
argument. Parallel test cloning is disabled for these phases so `simctl` and
XCUITest use the same device. Result guards reject failures, skips or missing
screenshots; `reinstall.json` is emitted only after all stages pass. This journey
is never satisfied by cached smoke or paired results.
The selected paired smoke is only one journey; full P-008 simulator acceptance,
device-specific capabilities, signed delivery and store review need their own evidence.

After native preflight passes, install the maintained macOS launch agent with
`python3 tools/ios-ci.py --install-launch-agent`. It invokes simulator checks at
login and every 30 minutes and preserves an explicit `DEVELOPER_DIR`. Inspect it
with `launchctl print gui/$(id -u)/com.papercusp.ios-ci`; stop it with
`launchctl bootout gui/$(id -u)/com.papercusp.ios-ci`. Logs live beside
`latest.json`. Retention keeps the newest 16 unsigned attempts, protects both
success pointers and preserves signed candidates and unrecognized directories.
Private signing and pairing inputs are redacted from retained phase logs.
Installation checks the simulator toolchain before changing launchd.

Signed exports are explicit and require a clean source and a new positive build number:

```sh
bash tools/build-scripts/ios-signing-secrets.sh plan
bash tools/build-scripts/ios-signing-secrets.sh apply
python3 tools/ios-ci.py --mode signed --build-number 42 \
  --secrets-file ~/.config/papercusp/ios-signing.json
# Add --upload --confirm-upload only when App Store Connect upload is authorized.
```

`ios-signing-secrets.sh apply` writes an atomically verified mode600 JSON outside
all source trees instead of publishing GitHub repository secrets. Copy that private
JSON to the Mac by an authenticated transfer if provisioning from Linux. Set
`PAPERCUP_IOS_SIGNING_CONFIG` to choose its path. It contains the existing seven
signing inputs (`APPLE_TEAM_ID`, distribution P12/password, App Store profile,
`ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, and `ASC_API_KEY_P8_BASE64`). The native
executor gates missing material before building, reserves build numbers, installs
a temporary keychain/profile/API key outside retained evidence, validates the signed
archive, optionally uploads, and cleans signing material even after a failed build.
Successful signed execution extends the existing `candidate-manifest.json` with
the shared release envelope: `schemaVersion`, `releaseVersion`, `sourceCommit`,
`sourceDirty:false`, `builtAt`, and one `ipa` artifact with relative path, byte size
and SHA256. The archive's validated identity and signing facts remain in that same
manifest. Failed, preflight and unsigned runs do not create an admissible release
envelope. The companion `result.json` records verification and the complete inventory.

### Manual iPhone download and registered-device installation

Manual delivery uses an **Ad Hoc distribution IPA**, exported with Xcode's
`release-testing` method. It requires Apple Developer Program membership, an
Apple Distribution certificate/private key, and an unexpired Ad Hoc profile for
this exact app/team that includes each recipient iPhone's registered UDID and
production Push Notifications. A downloaded IPA installs only on those devices;
a public link does not make it installable on arbitrary iPhones. Registering another
device requires a renewed profile and a new signed export. App Store listing,
TestFlight submission, ASC app record and API key are separate from this route.

Keep one Ad Hoc `.mobileprovision`, the matching distribution certificate and
`dist.key` in a private folder outside the source tree. Reuse the existing loader:

```sh
PAPERCUP_EXPORT_METHOD=release-testing \
  bash tools/build-scripts/ios-signing-secrets.sh plan
PAPERCUP_EXPORT_METHOD=release-testing \
  bash tools/build-scripts/ios-signing-secrets.sh apply
python3 tools/ios-ci.py --mode signed --distribution release-testing \
  --build-number 42 --secrets-file ~/.config/papercusp/ios-signing.json
# For the private backend journey add:
# --paired-ui --pair-payload-file /private/fresh-payload.json
```

The loader retains the existing `IOS_APPSTORE_PROFILE_BASE64` key for compatibility;
in this mode its value is the Ad Hoc profile. Only the four export inputs are
required. The runner refuses a store, development, enterprise, expired or wrong
app/team profile. It also validates the exported IPA's embedded profile and
distribution certificate. Upload is refused in `release-testing` mode. Installation
facts in the existing candidate manifest record the method, registered-device
count and profile expiry without exposing UDIDs.

After a real native pass, distribute the retained `export/*.ipa` with its SHA256.
On a registered device, download the IPA to a Mac, connect and trust the iPhone,
open Xcode **Window → Devices and Simulators**, select it, and add the IPA under
Installed Apps (or use Apple Configurator's Add Apps operation). Verify launch,
pairing, cloud reconnect and push on the actual phone, retaining candidate identity
and acceptance evidence. A Safari download link alone is not an installation flow;
over-the-air installation needs a separately hosted HTTPS installation manifest.
No installable IPA or device acceptance is implied by fixture tests or preflight.

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
temporary keychain outside retained evidence, and native executor cleanup
deletes it. `release-ios.sh` signs manually in this mode
(`PAPERCUP_SIGNING_STYLE=manual`). The profile reaches only the app target, via
`PAPERCUP_APP_PROVISIONING_PROFILE` in `ios/project.yml`. Local
`make release-ios` keeps automatic signing through the Mac's Xcode account.
`make test-ios-signing` covers all of this with fixtures.

### Source refresh without deleting native build caches

Use `tools/source-sync.py` for a local prepared source/destination pair. It
derives the transfer set from Git's tracked source inventory,
admits byte/file budgets before writing, copies only admitted files, removes
only stale tracked destination files, and verifies the existing native runner's
exact commit, recursive fingerprint and clean status after copying. Existing
ignored `target/`, Gradle, Xcode and other generated caches are preserved.

```sh
python3 tools/source-sync.py /prepared/source /prepared/native-checkout --dry-run
python3 tools/source-sync.py /prepared/source /prepared/native-checkout \
  --max-bytes 5368709120 --max-files 250000 --timeout 600
make test-source-sync
```

Both locations must be disjoint, clean Git checkouts with the same initialized
submodule paths. Visible untracked files, ignored destination collisions and
different private Firebase configuration are refused before source mutation.
The byte budget includes Git bundles for the root and submodules. Objects,
index and HEAD are updated without a checkout/reset that might delete caches;
the stable Git-local source-lock inode is preserved. Native iPhone execution
holds shared source custody for its complete run, while sync holds exclusive
destination custody from preflight through identity verification. An interrupted
copy must be repaired and verified before any acceptance run.

This helper operates on local prepared checkouts: prepare the incoming checkout
on the Mac first, then refresh its existing native checkout with this command.
It does not implement an SSH transport. Git subprocesses and file-copy loops use
the supplied time budget. Do not substitute whole-tree `rsync --delete`. Complete
source refresh and cache prewarming before starting a short-lived pairing fixture.

## Known issues

- **Xcode 16.2 destination race**: `xcodebuild` occasionally fails first-try with "iOS 18.2 is not installed" because the SDK and the only-installed 18.3.1 runtime mismatch on the destination resolver. The `make test-ios` wrapper retries 8x. Switching to Xcode 16.3 resolves it.
- **iOS voice mode requires Xcode 16.3+**. ElevenLabsSDK pulls LiveKit + livekit-uniffi-xcframework + JWTKit transitively. Xcode 16.2's SwiftPM dep-order resolution fails to build these in the right order, surfacing as `no such module 'LiveKitUniFFI'` and then `no such module 'Crypto'`. Same dep-resolution fragility as the destination-resolver race above. Android voice path is unaffected (Maven Central + Gradle handles deps cleanly).
- **`xcodebuild test -scheme` post-Sentry**: Permanently broken since the Sentry SwiftPM landed — the package resolver loses sim devices in Xcode's cache. Workaround: per-target builds (`xcodebuild -target Papercup`, `-target PapercupTests`, `-target PapercupUITests`).
- **CI triggers**: The independent Android timer observes managed `[skip ci]` commits. Read `latest.json`, source identities, executed tests and retained artifacts before claiming coverage; revalidated cached proof is not a new journey.
- **Apple Developer Program**: Required for APNs delivery, NetworkExtension entitlement (mesh), and TestFlight. iOS push + mesh code is wired but inert without enrollment.

## Hardware verified

- Android: Samsung Fold5 `RFCW80RTBGJ` (intermittently drops off `adb`), x86_64 emulator AVD `papercusp-test`.
- iOS: iPhone 16 simulator UDID `428F2FFE-9921-470D-9D46-E23563CE02CA` inside macOS Sonoma 14.8.5 QEMU/OSX-KVM VM (Threadripper Linux host).

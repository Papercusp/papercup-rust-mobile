# App Store review and submission packet — iPhone 1.0

_Refreshed October 1, 2026 for bundle ID `com.papercuspai.operator.mobile`. This packet is preparation, not proof of submission or public availability._

## Review notes

Papercusp is a companion to a Papercusp desktop operator controlled by the app
user. The app has no public sign-up or paid features. On first launch, pair it by
scanning or pasting the pair payload supplied with the review submission.

Pairing guidance follows desktop Settings → Remote access → Pair a phone.
After pairing, the tabs show the operator inbox (including system-health alerts),
chat, plans, current fleet/pot availability, notifications, and settings.
Availability counts describe reachable agent presence, not running jobs.
Desktop-local voice sends data to the paired
operator. Optional cloud voice remains blocked until the reviewer accepts a
separate disclosure naming ElevenLabs and the configured AI provider; consent
can be revoked in Settings.

Camera access is used only for scanning the pair QR code. Microphone access is
used for voice; configured Android builds also use it for continuous wake-word
listening after microphone permission is granted, with a foreground-service
notification. Notification permission is optional. Face ID is
used only to confirm high-risk actions on supported devices.

The privacy policy is available before pairing and in Settings:
<https://papercusp.com/mobile/privacy>. Support is available at
<https://papercusp.com/mobile/support>.

## Reviewer-access requirement

The production pair token is short-lived and one-use, so it must not be pasted
into review notes in advance. Before submission, provide App Review a dedicated,
sanitized, internet-reachable operator environment and a review-safe access path
that remains valid for the entire review window. The release cannot be submitted
until that path has been exercised from a clean install. If App Review approves
an in-app demonstration instead, record that approval and attach a video showing
the complete paired flow.

## Submission checklist

- App Store Connect app record uses bundle ID
  `com.papercuspai.operator.mobile`, version 1.0, and a unique build number.
- Support, marketing, and privacy URLs resolve publicly with no authentication.
- App Privacy answers match `store/APP-STORE-PRIVACY.md` and the exported
  archive's privacy report.
- Exported archive is built with the iOS 26 SDK or later and validates through
  App Store Connect.
- Apple Distribution certificate and App Store provisioning profile include
  Push Notifications for the production bundle ID.
- Screenshots come from the exact release candidate and cover the pair screen,
  inbox, chat, plans, running work, settings, privacy, and cloud-voice consent.
- The dedicated reviewer environment contains no private workspace data and is
  monitored throughout review.
- All App Store metadata and review attachments contain final values.
- Record the exact candidate source SHA, version/build, archive/IPA hashes,
  accepted Apple SDK, executed unit/UI cases and signed distribution identity.
  Preserve current native CI artifacts and TestFlight/Apple processing receipts.
- Actual paired UI, cellular, APNs, permission/Bluetooth/lifecycle and endurance
  checks are separate from clean-install simulator smoke. Missing hardware or
  signing capability leaves those outcomes unverified.
- Distribution rights are documented for every copyright holder because this
  repository is currently licensed under GPL-3.0-or-later and App Store terms
  may add restrictions that require separate permission.

## Final operator commands

Run the non-signing verification at any time:

```bash
make test-ios-release
```

On a current macOS/Xcode host with signing credentials installed:

```bash
PAPERCUP_DEVELOPMENT_TEAM=TEAMID \
PAPERCUP_BUILD_NUMBER=1 \
make release-ios ACTION=export
```

Validate the exact exported IPA using an App Store Connect API key:

```bash
PAPERCUP_IPA_PATH=/absolute/path/to/Papercusp.ipa \
APP_STORE_CONNECT_API_KEY_ID=KEYID \
APP_STORE_CONNECT_API_ISSUER_ID=ISSUERID \
make release-ios ACTION=validate
```

Upload only after the archive, metadata, screenshots, reviewer access, and
licensing clearance have all passed their release checks.

## Android / Google Play reviewer preparation

Use the shared pairing and privacy guidance above for Android, with these
platform-specific requirements. This section is a draft; reviewer access has
not been provisioned or verified, and no Google Play submission is recorded.

- Bind the final instructions and screenshots to the signed APK/AAB recorded
  in `android/app/build/outputs/papercusp-release-provenance.json`, including
  package, version code, source commit, artifact hashes and signing identity.
- Provide a sanitized, HTTPS-reachable paired operator for the review window.
  From desktop Settings → Remote access → Pair a phone, generate the pairing
  payload. In Android, use **Scan QR** or the paste-payload action. Verify the
  complete path from a clean install, including paste when camera access is
  denied; the on-screen desktop guidance must agree with the supplied notes.
- Supply working access through Play Console's app-access surface. Google's
  [review-access requirements](https://support.google.com/googleplay/android-developer/answer/15748846)
  require reusable access that stays available across locations, with English
  instructions and a static URL for QR/barcode access resources. Production
  pair tokens expire and are single-use, so an old payload in static notes is
  insufficient. Exercise the reviewer path repeatedly from separate clean
  installs without relying on expired or already-redeemed tokens. Recheck the
  approved path throughout the review window and retain its counterpart version
  and sanitized journey evidence.
- Verify inbox, chat, plans, fleet/pot availability, approvals and notifications
  on that environment. Exercise both voice routes: desktop-local voice and
  separately consented cloud voice, followed by consent revocation in Settings.
  Record permission denial and offline recovery behavior without promising
  that every feature works when its required permission is denied.
- Use the final `store/DATA-SAFETY.md` answers only after the provider-account
  and exact-candidate checks pass. Include Firebase Messaging/Crashlytics,
  optional ElevenLabs processing, the merged permissions, and publicly
  reachable privacy/support/deletion guidance.
- Record whether the exact Android build configures wake-word listening. When
  enabled, verify idle/background microphone capture, the foreground-service
  notification, permission-denied behavior and teardown. A dormant keyless build
  does not prove configured behavior. Reconcile the microphone foreground-service
  declaration and its demonstration with the actual candidate; do not describe
  its microphone as active only after tapping voice. Before submitting, verify
  the hosted policy includes the candidate's wake-word disclosure; the October 2
  source-policy update alone does not prove the public page was updated.
- Capture the candidate's Android phone screenshots and 1024 × 500 feature
  graphic specified in `store/LISTING.md`. Document distribution rights and
  required third-party notices; record the corresponding source location and
  license obligations for the shipped GPL-3.0-or-later build.

Candidate bytes, reviewer access, provider settings, final disclosures, assets
and licensing evidence remain acceptance requirements. A launcher smoke test
does not verify this reviewer journey or the physical-phone/Play-install matrix.

### Android license and source evidence

This is a source-based inventory, not distribution clearance. Resolve the
actual release runtime graph and packaged native libraries before finalizing
it; direct dependencies alone omit transitive and native components.

| Component | Existing source evidence | Evidence still required for the shipped candidate |
|---|---|---|
| Papercusp mobile and Rust core | Root `LICENSE` and workspace `Cargo.toml` declare GPL-3.0-or-later. | Exact corresponding source, build instructions, copyright/license notices and a recipient-accessible source delivery path bound to the candidate commit. A private repository URL alone does not establish recipient access. |
| ElevenLabs Android 0.9.0 and its voice transport dependencies | `android/app/build.gradle.kts` includes `io.elevenlabs:elevenlabs-android:0.9.0`; the [official SDK repository license](https://github.com/elevenlabs/elevenlabs-android/blob/main/LICENSE) currently identifies MIT terms. | License/copyright notices from the resolved 0.9.0 artifact and every included transport/native dependency. SDK licensing does not verify account service terms, retention or privacy settings. |
| Picovoice Porcupine Android 4.0.0 | Gradle includes the SDK; `WakeWordEngine.kt` initializes it only when configured. The [public repository license](https://github.com/Picovoice/porcupine/blob/master/LICENSE) and [current service terms](https://picovoice.ai/docs/terms-of-use/) are separate evidence surfaces. | Exact artifact/model/engine license terms and the applicable account agreement/entitlement. Do not infer clearance for packaged binaries or configured service use from the public wrapper license or a working AccessKey. |
| Firebase, ML Kit, AndroidX, Compose, OkHttp, JNA and Rust dependencies | Android Gradle declarations, `Cargo.lock`, and the packaged library/notice inventory. | Complete resolved release graph, license texts and required notices, including native payloads. Verify accessibility of the final notices and any source delivery required by the applicable licenses. |

The retained October 2 source preparation report comes from Gradle
`:app:dependencies --configuration releaseRuntimeClasspath` on mobile commit
`e5719e09330586b256120adc132b148810f520fa`. Its complete output is
`android/app/build/ci-evidence/p007-release-runtime-dependencies-20261002.log`
(SHA-256 `72d5fc540fce8fab2ad3ef17c02b8b6fd35cfea3a5983ec58bd5593f95d4f350`).
Selected resolved direct entries relevant to this review are:

| Gradle module | Resolved version |
|---|---|
| `ai.picovoice:porcupine-android` | `4.0.0` |
| `io.elevenlabs:elevenlabs-android` | `0.9.0` |
| `com.google.firebase:firebase-messaging-ktx` | `24.1.0` |
| `com.google.firebase:firebase-crashlytics-ktx` | `19.2.1` |
| `com.google.firebase:firebase-analytics-ktx` | `22.1.2` |
| `com.google.mlkit:barcode-scanning` | `17.3.0` |
| `net.java.dev.jna:jna` | `5.19.1` |
| `com.squareup.okhttp3:okhttp` and `okhttp-sse` | `4.12.0` |

The report resolves versions beyond declarations, including
`androidx.core:core-ktx` from `1.15.0` to `1.16.0`. The Firebase `33.6.0`
and Compose `2024.10.01` BOMs supply version constraints; they are not a
packaged-library inventory. Reconcile the full transitive report, Rust/native
payloads and license texts with the exact signed candidate's packaged contents
and final notices. A resolved SDK does not establish its runtime activation,
collection behavior, account entitlement or distribution rights. In particular,
the Firebase entries still require the existing candidate-bound collection and
disclosure checks even when source collection defaults are disabled.

The inspected local debug and historical release APKs contain several AndroidX
license entries and OkHttp's public-suffix notice. This limited filename-based
inspection does not prove completeness or apply to a new candidate. Re-inspect
the exact signed APK/AAB, and retain the complete inventory with its hashes.

Picovoice's current terms also describe operational usage reporting. If the
candidate activates its engine, review the provider's privacy policy, actual
runtime behavior, and corresponding public/in-app/Data Safety disclosures.
An unconfigured dormant engine is not evidence of the configured behavior.
The existing candidate/provider checklist remains open until this is measured.

### Retained voice/native dependency references

The following October 2 preparation read inspects the cached AARs named in the
retained release-runtime graph above and their version-specific Maven Central
POMs. These are dependency references, not proof of the final APK/AAB contents
or a complete notice bundle. POM license labels describe published metadata;
they do not establish rights for every binary, model or bundled dependency.

| Resolved module | Cached AAR SHA-256 | Version-specific metadata license label |
|---|---|---|
| `ai.picovoice:porcupine-android:4.0.0` | `be02724bde227b0f5f0c87da239065f77651051b3e81356dc7b3866c0d7882ff` | [Apache License - v2.0](https://repo.maven.apache.org/maven2/ai/picovoice/porcupine-android/4.0.0/porcupine-android-4.0.0.pom) |
| `ai.picovoice:android-voice-processor:1.0.2` | `6f225a9758bfdbaa7192a8297925be66a673b1b32eaaa4ed6ee0aeaa57746305` | [Apache License - v2.0](https://repo.maven.apache.org/maven2/ai/picovoice/android-voice-processor/1.0.2/android-voice-processor-1.0.2.pom) |
| `io.elevenlabs:elevenlabs-android:0.9.0` | `820281847cae389ee07c8414449d8c54f508bd172e87860c036e480652745054` | [MIT License](https://repo.maven.apache.org/maven2/io/elevenlabs/elevenlabs-android/0.9.0/elevenlabs-android-0.9.0.pom) |
| `io.livekit:livekit-android:2.22.0` | `021b060f5a9cc3a2efc088b212836194c162b87a99b6ac7c42b8f646b0dedae7` | [Apache Software License, Version 2.0](https://repo.maven.apache.org/maven2/io/livekit/livekit-android/2.22.0/livekit-android-2.22.0.pom) |
| `io.github.webrtc-sdk:android-prefixed:137.7151.04` | `07934f87e0c3897fd8107f9193eda0f35007c3aee92b4e085b909ed0fe3fd66c` | [3-Clause BSD License](https://repo.maven.apache.org/maven2/io/github/webrtc-sdk/android-prefixed/137.7151.04/android-prefixed-137.7151.04.pom) |
| `net.java.dev.jna:jna:5.19.1` | `b57125cb7d16253f0d65a80f7d3a4c3664effa711b8bdbb7f87fb572ce1624ed` | [LGPL-2.1-or-later and Apache-2.0](https://repo.maven.apache.org/maven2/net/java/dev/jna/jna/5.19.1/jna-5.19.1.pom) |

The inspected AARs contain `libpv_porcupine.so`,
`liblkjingle_peerconnection_so.so`, and `libjnidispatch.so` respectively for
Porcupine, WebRTC and JNA. JNA's cached AAR also includes obsolete `armeabi`,
`mips` and `mips64` payloads; the existing release ABI filter must continue to
exclude those from the shipped artifacts. Inspect the final native payloads
and their notice/source requirements separately from Java wrapper licensing.

A filename scan of these six AARs and their nested JARs found
`classes.jar!/META-INF/LICENSE` in JNA. The other five returned no filename
containing `license`, `notice` or `copying` in this bounded inspection. This
does not establish absence of license text in every resource, prove a license
violation, or satisfy notice delivery. Obtain the version-specific upstream
copyright/license texts and reconcile them with the candidate's notice bundle.

Corresponding source must also include the source used from the `libs/token-kit`
submodule. At preparation commit `2625dab7e39dd5e093922a4ddd0610ea384b4c4c`,
the gitlink and checked-out submodule both identify
`0a2c7214d928c8b330a7ae9584876089e2781634`; its `LICENSE` contains Apache 2.0
terms. A root-only Git archive omits submodule contents, and a private clone URL
does not give a recipient access. Bind the final source delivery to the
candidate's actual gitlink, include build instructions and applicable notices,
and verify retrieval as a recipient before claiming source delivery complete.

The existing Android provenance producer now creates
`android/app/build/outputs/papercusp-mobile-source.tar.gz` when writing release
provenance. It records the archive's size and SHA-256 in the same artifact map
as the APK/AAB and verifies its committed file contents and recursively pinned
submodule sources. The archive includes `SOURCE-PROVENANCE.json`, root build
instructions and tracked license files. Missing, dirty or mismatched submodule
checkouts are rejected. For local preparation from a clean checkout:

```sh
tools/build-scripts/android-release-provenance.sh source-archive
```

This archive provides the mobile repository's source contribution. It does not
by itself include every third-party dependency's corresponding source, establish
licensing clearance, or make a private artifact accessible to recipients. Before
distribution, supplement any required dependency sources/notices, bind the final
delivery to the candidate and verify actual recipient retrieval. Do not publish
the source archive merely because local preparation passed.

### Locked Rust dependency source preparation

The October 2 local preparation at mobile commit
`f41bf7f40ea3a633271ac3d3747b40e43307e39b` also uses Cargo's maintained
vendoring command:

```sh
cargo vendor --frozen --versioned-dirs \
  android/app/build/outputs/papercusp-rust-dependencies \
  > android/app/build/outputs/papercusp-rust-source-config.toml
```

The resulting population matches all 249 registry packages in the retained
`Cargo.lock` (SHA-256
`389f43b2d8d5fec43b35c2dc71246e0fd395a598ec9517516b54c8e8c6746c81`).
All 12,321 file digests recorded in their `.cargo-checksum.json` files were
verified. This inventory includes host, development and platform-specific
dependencies; it does not identify which crates are linked into an Android
candidate. No Git dependency appears in this locked population.

The filename-based notice scan was supplemented by reading `r-efi` 5.3.0's
`AUTHORS`, which retains its permission/copyright text. Nine UniFFI 0.32.2
packages declare MPL-2.0 and contain MPL source headers. Their packaged
`.cargo_vcs_info.json` identifies upstream revision
`7bc621ee9d0d15371d792612707ba5ed4111f950`; the full
[license text at that revision](https://raw.githubusercontent.com/mozilla/uniffi-rs/7bc621ee9d0d15371d792612707ba5ed4111f950/LICENSE)
was retained separately, with SHA-256
`1f256ecad192880510e84ad60474eab7589218784b9a50bc7ceee34c2b91f1d5`.
The vendor files remain unmodified, so their original Cargo checksums still
apply. These texts and sources support review; they do not by themselves
finalize the candidate's notices or license obligations.

The private local supplementary archive is
`android/app/build/outputs/papercusp-rust-dependencies.tar.gz` (42,672,304
bytes; SHA-256
`c3e3ef5c280b270deb739ba1341443d47cbd3fe3afb7693b14c74df0ee570f8d`).
It extracts into the same `papercusp-mobile-source` directory as the retained
root source archive. It supplies the vendor directory, its inventory, the
revision-pinned MPL supplement and `.cargo/config.toml` pointing at the
extracted vendor directory. Actual local extraction of both archives followed
by `cargo metadata --frozen --format-version 1` resolved all 249 registry
packages from that extracted directory and re-verified their 12,321 file
digests. The receipt is
`android/app/build/outputs/papercusp-rust-source-extraction-result.json`
(SHA-256
`9dd80dad718af3ec088b50f34112c8ddde1c02e81019e0e0d1f80b41f2561575`).
Temporary extraction was removed afterward.

This proves local source extraction and Cargo graph resolution for the recorded
revision. Compilation, Android/Gradle/native SDK source obligations, final
notices, licensing clearance and actual recipient retrieval remain open.

The existing source-provenance helper provides a repeatable exported-source
compilation check, after the root archive and locked Rust supplement are prepared:

```sh
tools/build-scripts/android-release-provenance.sh source-verify-build host
tools/build-scripts/android-release-provenance.sh source-verify-build android
```

It verifies the root archive against the current committed source, extracts both
archives into a temporary directory, verifies the complete locked registry and
file checksums, and resolves Cargo dependencies exclusively from delivered
source. Compilation uses `--frozen` with offline mode and an empty target
directory. Android mode builds the Rust native library for all four supported
ABIs through cargo-ndk. A successful receipt records archive, lockfile, output
and unique log hashes in
`android/app/build/outputs/papercusp-source-build-result.json`. Native app
compilation, signed-candidate equivalence, complete notices, license clearance
and recipient retrieval require separate evidence. The maintained provenance
test compiles a real miniature vendored dependency and rejects stale or damaged
supplements, root-file replacement, unsafe/duplicate entries, redirected Cargo
configuration and a real Rust compiler failure.

For an actual debug APK build from the delivered source, explicitly supply the
API 36 SDK and external Firebase configuration:

```sh
export ANDROID_SDK_ROOT="$HOME/Android/Sdk"
export PAPERCUP_SOURCE_GOOGLE_SERVICES="/path/to/private/google-services.json"
tools/build-scripts/android-release-provenance.sh source-verify-build android-apk
```

This mode rebuilds all four Rust ABIs and generates Kotlin bindings with frozen,
offline Cargo resolution, then runs the delivered Gradle wrapper with offline
dependency resolution. It shares existing Gradle dependency/distribution caches
through an isolated user home; personal Gradle properties, init scripts, signing
and wake-word environment overrides are excluded. The receipt hashes the external
Firebase config without copying its contents or private path into evidence, records
Java/Rust versions and SDK package metadata, and inventories the resolved runtime,
compile, desugaring and project buildscript artifacts. This inventory is not a
complete hermetic toolchain or dependency-source delivery claim.

A real Gradle init/plugin/dependency preflight uses the same isolated route before
native compilation. The generated init script lives under the Android project,
where Gradle resolves its relative `--init-script` option with `-p android`.

The generated Kotlin command replaces Gradle's unfrozen `make bindings-kotlin`
task explicitly. The existing UniFFI ABI verifier checks the generated bindings
against all four compiled libraries before Gradle runs. The source verifier also
checks all four packaged Rust libraries against this
Gradle build's stripped outputs and retains a uniquely named debug APK and build
log alongside the receipt. A failure removes the preceding successful receipt;
a compiler/Gradle failure retains its exit code and unique log. Maintained fixture
tests check orchestration, external-config isolation, ten rejecting controls and
a private copy that reintroduces the original init-path defect before compilation;
they do not claim real Android compilation. A separately recorded operational run
must establish that. Debug compilation does not establish signed APK/AAB candidate
equivalence, complete notices, licensing clearance or recipient retrieval.

### Selected Android SDK source and notice preparation

The October 2 preparation at mobile commit
`143aad60db1e253552eb84dc8768aa9695b52275` retains the six version-specific
Maven Central POMs and source JARs for the voice/native modules inventoried
above. Private local evidence is in
`android/app/build/outputs/papercusp-android-dependency-sources/PROVENANCE.json`
(SHA-256 `1be56c04b197580764d243f0ae081d5b959c9fcb58ebf7589448fba5bacf3aef`).
It records the download URLs, sizes, hashes, source-file counts and notice
paths. All 24 retained evidence-file hashes were checked after writing.

| Module | Source JAR SHA-256 | Java/Kotlin/C/C++/header entries |
|---|---|---|
| `ai.picovoice:porcupine-android:4.0.0` | `49d3bee7ce35e13da99de8fceaa48f725a2bbbe8cb395603cb350740a7395f32` | 17 |
| `ai.picovoice:android-voice-processor:1.0.2` | `e52af65540876e11621e370a256f480bf43378669b82a3c9e11e216ed1b4a223` | 7 |
| `io.elevenlabs:elevenlabs-android:0.9.0` | `59c163f6453c6806555881f47d3cdc7c6cc655469176e861c7636b4998075d07` | 30 |
| `io.livekit:livekit-android:2.22.0` | `b3a146cd26c751114d0a91866eee3cc641b8b6336f7cf4ad999081b65964a693` | 252 |
| `io.github.webrtc-sdk:android-prefixed:137.7151.04` | `18dc05a4d201cdf4c7580d59ded2ae92f44926f45a8eb55ae2574209100acf6a` | 0 |
| `net.java.dev.jna:jna:5.19.1` | `0136f719ddd91d92d2368aa2c59a0c436810ac0b9c29024044383758b0e99786` | 66 |

The counts include generated source entries where present. None of these six
source JARs contains a filename matching `license`, `notice` or `copying`.
The WebRTC source JAR is 206 bytes and contains only its manifest; downloading
it does not supply the native engine source.

The same evidence directory retains these upstream release-tag references:

- ElevenLabs `v0.9.0`, commit `3fa8d85ec2443982dd2561e0c2e8fc2f7c3ca378`:
  [MIT license and copyright text](https://raw.githubusercontent.com/elevenlabs/elevenlabs-android/3fa8d85ec2443982dd2561e0c2e8fc2f7c3ca378/LICENSE).
- LiveKit `v2.22.0`, commit `e5af72ed521ca000a8636b483731a888746a4c64`:
  [LICENSE](https://raw.githubusercontent.com/livekit/client-sdk-android/e5af72ed521ca000a8636b483731a888746a4c64/LICENSE)
  and [NOTICE](https://raw.githubusercontent.com/livekit/client-sdk-android/e5af72ed521ca000a8636b483731a888746a4c64/NOTICE).
  The notice includes LiveKit, Shiguredo, SDP parser and WebRTC material;
  preserve that complete text when preparing the applicable distribution notices.
- Porcupine `4.0.0`, commit `c794ad57b189f4b06e8128abd0324ad09e1a424d`:
  [LICENSE](https://raw.githubusercontent.com/Picovoice/porcupine/c794ad57b189f4b06e8128abd0324ad09e1a424d/LICENSE).
  Engine/model/account terms remain a separate review requirement.
- JNA `5.19.1`, commit `1a91122853f6ab6f1fb2a4a284a6cf2ed8af0a4d`:
  `LICENSE`, `AL2.0`, `LGPL2.1` and
  [native libffi copyright/license text](https://raw.githubusercontent.com/java-native-access/jna/1a91122853f6ab6f1fb2a4a284a6cf2ed8af0a4d/native/libffi/LICENSE).
  Retaining both offered JNA license texts does not decide the distribution's
  license choice or establish complete native dependency coverage.

For `android-voice-processor:1.0.2`, all seven Java files in the retained source
JAR byte-match upstream revision `2bd8e3b6bc09d4d0c6c9202173b7ccc576bc5088`.
Its [LICENSE](https://raw.githubusercontent.com/Picovoice/android-voice-processor/2bd8e3b6bc09d4d0c6c9202173b7ccc576bc5088/LICENSE)
is retained as `voiceprocessor-LICENSE` (SHA-256
`930c1bf076c9477108de5d2b053b5aa682bd68ee215f183f783207aaf2bc0153`).
The separate `voiceprocessor-SOURCE-MATCH.json` receipt has SHA-256
`a6e8261d58aeb9fb2d624db91e1bc682893daae9812fb39bf180cd57edba0a78`.
This binds the Java source comparison and license reference to a recorded
revision; it does not prove which build produced the Maven binary.

WebRTC's packaging tag `v137.7151.04` points to
`f126941a2667f8f1bd3ac60b1a6a4783a3310e1f`. Its pinned download script imports
the release's `libwebrtc_prefixed.aar` and renames the native library. The
downloaded release asset's SHA-256 is
`76b7fc94ac3a16b81bd42f0e8bf781636ad52f815d296f1c0c314271fd1ed262`.
The four native payloads in the retained Gradle AAR byte-match that asset for
`arm64-v8a`, `armeabi-v7a`, `x86` and `x86_64`, accounting for the name change.
This establishes that bounded native-byte relationship. The packaging
repository's MIT text and Maven's BSD metadata concern different evidence
surfaces; neither alone supplies a complete native dependency notice census.

These files remain private local preparation. Upstream release tags are not
proof that those revisions produced the Maven artifacts. Full
transitive/native/model coverage, final notice accessibility, candidate binding, distribution rights,
compilation and actual recipient retrieval remain open.

### Generated Android dependency metadata

The Android build uses the maintained AboutLibraries Gradle plugin to generate
variant-specific `raw/aboutlibraries.json` resources. The existing release
export is also available with:

```sh
JAVA_HOME="$(tools/build-scripts/resolve-java-home.sh)" \
  android/gradlew -p android :app:exportLibraryDefinitions
make test-android-library-notices
```

The maintained check compares the generated release resource with Gradle's
actual `releaseRuntimeClasspath` module IDs and selected versions. It rejects
omitted modules, stale versions, test-only dependencies and missing standard
license text. It runs in `make check` and the Android host/full gate.

The first local export contains 210 release library records and nine license
records. Five license records contain links without license text: CameraX's
libyuv BSD reference, WebRTC's BSD reference, ML Kit terms, Android SDK terms
and the JAIN SIP public-domain reference. These require explicit review and
supplemental text where applicable. Generated POM metadata does not include
every native/model notice, Rust license or upstream copyright notice; it does
not prove distribution rights or complete recipient-visible notice delivery.
Recreate the contributions from the exact final candidate revision and verify
the final delivery before publication; these retained preparation archives
have not been published.

### In-app Android license access

The pairing screen and Settings → About now open **Third-party licenses**.
Users can read bundled license text without pairing or opening a website.
The existing AboutLibraries collector supplies the variant-specific resource;
its maintained Material 3 viewer supplies the list and license dialog.
The viewer uses version 11.2.2, whose published Kotlin 2.0 dependencies fit the
app's current compiler. The independently versioned collector remains 12.2.4.
The dialog preserves every supplied license and linked reference for a library.
Linked-only records still require the applicable supplemental text before
complete distribution-notice acceptance; a visible link does not satisfy that
requirement by itself.

The collector's resolved dependency data is marked `@Internal` in version
12.2.4. The Android build therefore adds runtime artifact and selected module
graph inputs to its existing debug/release preparation tasks. The maintained
notice check exercises a cached add/remove transition using a private local
Maven fixture: 221 normal release records, 222 with the fixture, and 221 after
removal. It also retains the four damaged-metadata rejection controls.

On October 2, the maintained debug and release unit suites each passed 36
tests. Three additional native Compose tests passed on an owned API 36 / 16 KB
emulator: unpaired access to actual bundled license text and return navigation,
multiple license texts plus linked-only terms in the dialog, and a resource
failure message. These are current debug UI checks, not signed-candidate,
physical-phone, complete corresponding-source, distribution-rights, or Play
acceptance. The release packet still requires final candidate binding and the
supplemental native/model/Rust notices and recipient retrieval described above.

### Supplemental Android notice text

The collector now reuses its supported `collect.configPath` overrides in
`android/config/licenses`. Five previously linked-only records have bundled
text. `android/config/SOURCES.json` records each original license ID, content
SHA-256, upstream source URL and digest, retrieval time, and the selected module
versions which reference it. The maintained metadata check verifies the actual
debug/release output against these files and rejects missing, substituted or
unlinked text. No new notice viewer or separate generation pipeline was added.
The cache-transition check uses a temporary app build directory, preserving
the normal packaging resources even when it runs from the automatic pre-push
gate. It asserts that both preparation tasks keep their outputs in that
directory.

| Reference | Retained text and scope |
| --- | --- |
| CameraX libyuv BSD reference | Full LibYuv LICENSE at upstream revision `aa6cedb39c87910b4c28e5c71c2121fc45fd234b`, including copyright and disclaimer. This upstream license snapshot does not identify the exact native source revision compiled into CameraX 1.4.0. The resolved CameraX AAR's own LICENSE contains Apache-2.0 text. |
| WebRTC BSD reference | Full WebRTC LICENSE at branch-7151 revision `cec4daea7ed5da94fc38d790bd12694c86865447`, including copyright and disclaimer. This complements the retained native byte comparison; it does not prove complete third-party native-source/notice coverage. |
| ML Kit terms | The complete official Terms & Privacy article retrieved October 3 UTC, last modified May 14, 2025, with referenced URLs preserved in the text. It incorporates Google API terms and describes performance/utilization metrics sent to Google; processor/privacy and account acceptance still require separate review. |
| Android SDK terms | The complete official SDK agreement retrieved October 3 UTC, dated April 28, 2026, including sections 1–14. The snapshot is readable offline; it does not establish account acceptance or determine distribution rights for every Google dependency. |
| JAIN SIP | Exact published `android-jain-sip-ri:1.3.0-91` source JAR's NIST Conditions Of Use header and full `javax/sip/copyright.html` text. The latter reserves Sun/BEA API copyrights and says use is subject to license terms. The POM's public-domain label must not erase that distinct notice or be taken as blanket redistribution clearance. |

These supplements preserve the cited text for in-app access. Complete
transitive/native/model/Rust notices, applicable source compilation, precise
binary/source matching, recipient-accessible source delivery and distribution
rights remain open. Refresh the source/version review for the final signed
candidate; these local snapshots do not satisfy Play or physical-phone
acceptance.

On October 3 UTC, the retained exported-source debug APK was checked without
rebuilding its app/native bytes. Four maintained native notice tests passed on
an owned read-only API 36 / 16 KB emulator with networking disabled. The new
test compares all five complete supplemental texts with their source-pinned
hashes, opens their bundled-library dialogs without pairing, and returns to
the pairing screen. A private APK copy with one supplemental text removed
failed the same test; restoring the exact original APK restored the pass.
The proof distinguishes app commit `68bc8893` from test commit `131ce62f` and
retains both APK hashes. This is debug preparation, not signed-candidate,
complete rights/notices, recipient retrieval, physical-phone or Play acceptance.

The existing native runner now checks framework processes, settings-service
responses and crash-buffer evidence in addition to the boot flag before
installation. Its maintained suite rejects missing/restarting processes,
broken service responses and the observed SurfaceFlinger DMA assertion.
The API 36.1 image originally crashed with that assertion using both indirect
and current SwiftShader renderers. A controlled same-image, same-launch-flags
comparison then reproduced the failure with default graphics negotiation and
prevented it with both `GLDirectMem` and
`HasSharedSlotsHostMemoryAllocator`. The maintained CI launch enables both;
API 36.1 and later admission requires the three corresponding host extension
tokens before installation. Fresh API 36.1 / 16 KB admission, actual screen
readback and later framework stability passed. Admission also requires at
least 512 MiB of measured free guest `/data` space, independently of host
capacity. Both readiness bugs are resolved with committed evidence on
`EI-24926092400277910` and `EI-24929048763433701`; their canonical proof is
`docs/evidence/android-emulator-dma-guest-readiness-local-2026-10-03.json`
in the Papercusp repository, test-run receipt `20631145`. This is local runtime
preparation. Removing the deprecated renderer option alone did not repair the
failure, and the separate API 36 result remains separate evidence.

### Retained debug native and model payloads

An October 3 read of the existing exported-source debug APK, SHA-256
`81bfbe9ff235dfc8480211b8974041c30a293b1629d85d6617d3bbab9bb8a3db`,
enumerated every `lib/**/*.so` ZIP entry. Each of the following seven families
is present in `arm64-v8a`, `armeabi-v7a`, `x86` and `x86_64`, for 28 payloads.
The inputs are bound to the retained exported-build receipt
`android/app/build/outputs/papercusp-source-build-android-apk-c0adc01280f54ac1.json`
(SHA-256 `c0adc01280f54ac134518efd6a2fe27a6a4bafa847feee59fea08c052624bb52`).
This read did not rebuild the APK or replay its native tests.

| Packaged library | Recorded input and measured byte relationship |
| --- | --- |
| `libandroidx.graphics.path.so` | `androidx.graphics:graphics-path:1.0.1`; all four payloads equal the resolved AAR's JNI entries. |
| `libbarhopper_v3.so` | `com.google.mlkit:barcode-scanning:17.3.0`; all four payloads equal the resolved AAR's JNI entries. |
| `libimage_processing_util_jni.so` | `androidx.camera:camera-core:1.4.0`; all four payloads equal the resolved AAR's JNI entries. |
| `libjnidispatch.so` | `net.java.dev.jna:jna:5.19.1`; all four payloads equal the resolved AAR's JNI entries after the matching NDK's `llvm-strip --strip-unneeded` transformation. |
| `liblkjingle_peerconnection_so.so` | `io.github.webrtc-sdk:android-prefixed:137.7151.04`; all four payloads equal the resolved AAR's JNI entries, extending the earlier upstream-asset comparison to this APK. |
| `libpapercup.so` | All four payloads equal the exported-source Gradle build's stripped Rust outputs recorded in the same build receipt. |
| `libpv_porcupine.so` | `ai.picovoice:porcupine-android:4.0.0`; all four payloads equal the resolved AAR's JNI entries after the matching NDK's `llvm-strip --strip-unneeded` transformation. |

Each input AAR was hash-checked against that receipt's
`debugRuntimeClasspath` artifact inventory before comparison. For the eight
transformed inputs, the selected NDK's `source.properties` SHA-256 is
`1c4a54b31c5ed242a901b4a472d412819b5e08405df1c58066bd555f9dd52515`;
the `llvm-strip` executable SHA-256 is
`e0ea88a5ceb089d7e686f7083ba276f5dd1b89c94bfaa5edb6da8634dc9ebcce`.
The transformation reproduced the packaged bytes using temporary copies,
which were removed. It does not establish the original build command or the
upstream source revision that produced an SDK binary.

A whole-ZIP scan for `.tflite`, `.ppn`, `.pv` and `.onnx` filenames also found
three ML Kit barcode `.tflite` assets, fourteen built-in Porcupine `.ppn`
resources and `porcupine_params.pv`. All eighteen equal the same-path entries
in the resolved ML Kit or Porcupine AAR. This extension-based population is
explicit: models or data with other filenames are outside the scan. Packaged
keyword resources do not demonstrate wake-word activation or account entitlement.

Use these families and model resources to drive the final candidate's native
and model notice/source/rights review. Java wrapper license labels and the
existing five supplemental notice texts do not complete that review. Repeat
the payload census against the signed APK/AAB and bind the final notices and
corresponding-source supplements to its artifact identity. Exercise retrieval
from the actual recipient-accessible destination, then compile the retrieved
source through the existing verifier. Local archive extraction and this debug
byte comparison leave recipient delivery, complete obligations and release
acceptance open.

### Selected upstream native attribution delivery

The same AboutLibraries configuration now adds two retained upstream texts to
their existing module records. It uses supported `config/libraries` merges
and `config/licenses` definitions, preserving the resolved versions and
original license references. `android/config/SOURCES.json` extends the existing
source/hash ledger; no separate collector or notice viewer was introduced.

| Existing module | Additional offline text | Pinned reference and content SHA-256 |
| --- | --- | --- |
| `io.livekit:livekit-android:2.22.0` | Complete LiveKit NOTICE, including LiveKit, Shiguredo, SDP parser and WebRTC attribution. | Revision `e5af72ed521ca000a8636b483731a888746a4c64`, SHA-256 `1ddcdc49391b88daa34060c04a5c3ecaa324903abdca74010aad6edbd952ed72`. |
| `net.java.dev.jna:jna:5.19.1` | Complete upstream `native/libffi/LICENSE`, including the Anthony Green/Red Hat copyright, permission condition and disclaimer. | Revision `1a91122853f6ab6f1fb2a4a284a6cf2ed8af0a4d`, SHA-256 `2c9c2acb9743e6b007b91350475308aee44691d96aa20eacef8e199988c8c388`. |

These bytes match the previously retained release-tag references. They are
selected upstream attribution, not proof that every source component in the
packaged JNA or WebRTC engine is covered. JNA's Apache/LGPL alternative remains
visible; adding the libffi permission text does not decide that license choice.
The maintained graph check verifies the original labels, exact additional texts,
module versions and links, and rejects omitted, substituted or unlinked text.
The previously tested APK remains unchanged and contains the earlier five
supplements; these additions require fresh final-candidate packaging and native
access evidence before release acceptance.

The retained debug population defines the remaining review scope:

| Packaged family or resource population | Existing reference coverage | Remaining candidate-bound requirement |
| --- | --- | --- |
| Graphics Path 1.0.1 native library | Resolved AndroidX Apache-2.0 metadata. | Identify native source components and any additional notices; a wrapper label alone does not establish the native census. |
| CameraX 1.4.0 image-processing library | Apache-2.0 metadata and the retained complete LibYuv license snapshot. | Establish the native source revision and full notice population actually used for the candidate. |
| ML Kit 17.3.0 barcode engine and three `.tflite` assets | Complete retained ML Kit terms. | Confirm applicable engine/model distribution terms, provider obligations and candidate behavior; current terms do not establish account acceptance. |
| JNA 5.19.1 native dispatcher | Apache/LGPL labels plus the selected upstream libffi notice above. | Reconcile the complete native source/notice population and chosen license obligations. |
| WebRTC 137.7151.04 native engine | Complete retained WebRTC BSD text; LiveKit 2.22.0's complete upstream NOTICE is now separately linked to LiveKit. | Obtain the engine's full third-party notice/source census; an empty Maven source JAR and packaging MIT text do not supply it. |
| Rust `libpapercup.so` | GPL root source, pinned token-kit source and the existing locked Rust source supplement/verifier. | Deliver the applicable Rust dependency notices and corresponding source through the actual recipient-accessible route, bound to the signed candidate. |
| Porcupine 4.0.0 engine, fourteen `.ppn` files and one `.pv` file | Resolved Apache wrapper metadata and retained release-tag license reference. | Establish the engine/model terms, distribution rights and applicable account entitlement separately; bundled keywords and a working key do not establish them. |

This maps the seven native families and eighteen extension-selected model
resources already measured above. It does not expand that filename scan or
establish complete rights. Final signed-candidate inventory, notice access,
source-recipient retrieval/build, provider/reviewer journeys, current paired
automatic CI, physical-phone and Play evidence remain required.

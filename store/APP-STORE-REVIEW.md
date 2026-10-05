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

The same source verifier can prepare Rust notice metadata without compiling:

```sh
tools/build-scripts/android-release-provenance.sh source-notices
```

It verifies the delivered root archive, complete locked source supplement and
file checksums before collecting the inventory's full LICENSE, COPYING, NOTICE,
AUTHORS and COPYRIGHT files (including nested files), declared license files,
and revision-pinned supplements. Package license declarations must match the
delivered Cargo manifests; selected files cannot be omitted from the inventory.
Pinned supplements must match the package's recorded VCS revision. UTF-8 text
bytes are preserved, and identical texts share a content hash.

The generated `android/app/build/outputs/papercusp-rust-notices.json` uses the
existing notice viewer's library/license metadata format. Its separate
`papercusp-rust-notices-result.json` records source/archive/text hashes and
scope; producing it preserves the prior compilation receipt. This inventory
covers all locked registry packages, including host, development and other
platform dependencies. Generation alone does not package these records into
the app, identify Android-linked crates, exhaust source-header attributions,
choose among alternative license grants, clear distribution rights or prove
recipient access. Final app notice delivery and the candidate-bound review
remain required.

Actual October 3 production at mobile commit `8d3e99c8` verified all 249
locked registry packages and 12,321 vendor files, generating 162 distinct texts.
Those exact package/text definitions now extend the existing
`android/config/libraries` and `android/config/licenses` collector inputs.
`android/config/RUST-SOURCES.json` retains each source declaration, checksum,
selected text hash and pinned supplement reference. The ordinary collector
checks the Cargo.lock fingerprint before generation; a changed lockfile
requires reviewed regeneration. The maintained metadata check compares the
entire registry population and exact texts with this ledger and exercises
damaged Rust records as well as Android graph cache transitions.

This delivers supplemental lockfile records through the same generated resource
and viewer. It retains the broad inventory scope above; it does not claim that
every record is linked into Android or complete source-header/license clearance.
Final signed-candidate/native notice access and recipient delivery still need
their own evidence.

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
| Graphics Path 1.0.1 native library | Resolved AndroidX Apache-2.0 metadata plus the pinned native-source attribution described below. | Establish the native binary/build/source relationship and reconcile final candidate contents; Kotlin source matches alone do not prove it. |
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

### Graphics Path native source and attribution preparation

The official [Graphics Path 1.0.1 release notes](https://developer.android.com/jetpack/androidx/releases/graphics#graphics-path-1.0.1)
link the release to AndroidX revision
`8a05a22af450d589ef911d772a001a49dcb05b71`. The retained module subtree has
29 files; every file's Git blob identity was checked against that pinned upstream
tree. All four Kotlin files in the Maven 1.0.1 source JAR byte-match this tree.
That JAR contains no native source, so it supplies only the Kotlin comparison.

The subtree contains 12 native source/build files, including three C++ translation
units, seven headers, CMake instructions and the linker map. All ten C++/header
files carry Apache-2.0 comments. The existing AboutLibraries configuration now
retains the four distinct complete comments, including the 2006, 2013, 2017 and
2022 Android Open Source Project copyrights. This is derived attribution from
source comments, not an upstream file named NOTICE. The original Apache-2.0
license reference remains on the resolved module.

Private retained evidence is under the existing
`android/app/build/outputs/papercusp-android-dependency-sources/` directory:

| Evidence | SHA-256 |
| --- | --- |
| `graphics-path-SOURCE-MATCH.json` | `1f5049792febb83f520533a4285dd5742aa02fd3ef44b9872ad33de9c4691703` |
| Pinned upstream module archive | `7437f80f2b35aed4341f482064aa69d0108c4035769537b9430fc11bc0cb8027` |
| Maven 1.0.1 source JAR | `9f1b5995b9577a8876525c3411ebb2a49f9ef0e875f6aec3059e807596dc6ca6` |
| Pinned AndroidX root LICENSE | `809fa1ed21450f59827d1e9aec720bbc4b687434fa22283c6cb5dd82a47ab9c0` |
| Derived native source attribution | `09700dee0f298c3bde3435f539010e7f1b7ed50339a144d8907cd49094232a4b` |

The retained archive hash identifies the actual inspected download, while the
complete per-file Git blob checks bind its contents to the pinned source tree.
The source/header hashes and
extraction rule also live in the existing `android/config/SOURCES.json` ledger.
The maintained metadata guard rejects missing, substituted or unlinked attribution
and checks that the original Apache label survives. The native notice test now
pins this eighth text for future candidate execution.

No native rebuild or binary/source equivalence is established by these source
comparisons. The retained tested debug APK still has its original five supplements.
Final signed-candidate packaging, native notice access, full license/rights review
and actual source-recipient retrieval/build remain open.

### Porcupine engine/model terms preparation

The official Picovoice general FAQ, read October 3, 2026, distinguishes
open-source SDKs from proprietary models and inference engines. Keep the
Porcupine SDK's Apache notice, but do not extend that label to the measured
engine, fourteen `.ppn` resources or `porcupine_params.pv` without evidence.

The official Terms of Use snapshot was last updated March 18, 2026 and became
effective March 30, 2026. Sections 5–7 describe possible usage reporting,
application-use licensing conditional on terms and fees, additional agreements,
and restrictions. Trial access can end. Usage data may be stored locally and
sent when connectivity returns; on-device inference alone is not proof of
zero provider reporting. This is a reference review, not evidence that this
app actually transmitted data or that its account obtained distribution rights.

Private snapshots and normalized page extracts are retained in the existing
dependency-sources directory. `picovoice-TERMS-REFERENCE.json`, SHA-256
`95b724a12ff046f99bf8fbbb030211cc8814d6f7bdbf9e41dacf6c44a86d4fcb`,
records the two successful official URLs, retrieval times and raw/extracted
hashes. `android/config/SOURCES.json` adds these as `termsReferences`, not
as replacement license grants or new bundled notices.

Before the candidate is cleared, reconcile the applicable account agreement,
engine/model distribution scope, GPL-source obligations, effective key/custom
keyword configuration, and reporting/privacy behavior. No new approval request
or release clearance is implied by this preparation.

### CameraX native source preparation

The official CameraX 1.4.0 release notes, dated October 30, 2024, link to
AndroidX revision `1d117856fc5cbc071d379fe5ec64846d40bf584b`. Its retained
`camera/camera-core` archive has 555 files. All 323 Java/Kotlin entries in the
published Maven source JAR byte-match the production source roots. An initial
suffix-only comparison ambiguously matched `DeviceQuirks.java` to both main
and test sources; selecting `src/main/java` and `src/main/kotlin` resolves it
without a source substitution or missing-source claim.

The native directory contains exactly `CMakeLists.txt`,
`image_processing_util_jni.cc` and `jni.lds`; all three retained file Git blob
IDs match the pinned upstream entries. The build and C++ file retain their
2020/2021 Android Open Source Project Apache headers. The comparison receipt
is `camera-core-SOURCE-MATCH.json`, SHA-256
`81bf513e516fa3e9970640aeb675e0d0793e54499e267e054c1e4fe2de1bed8d`,
in the existing private dependency-sources directory.

CMake imports `libyuv::yuv`. The pinned `external/libyuv` Gradle wrapper points
outside this AndroidX tree to `../../external/libyuv`; its README confirms that
the static library is packaged into CameraX. These files do not pin the
external LibYuv source revision that produced the distributed native binary.
The earlier complete LibYuv license snapshot remains a reference, not that
missing revision proof. Native binary/source equivalence, complete obligations,
signed-candidate notice access and actual recipient retrieval remain open.


### WebRTC third-party notice preparation

The pinned packaging revision `f126941a2667f8f1bd3ac60b1a6a4783a3310e1f`
contains `Licenses/WEBRTC.md`, a complete upstream notice reference with 30
top-level component headings, from WebRTC through zlib. The retained
[788,358-byte file](https://raw.githubusercontent.com/webrtc-sdk/android/f126941a2667f8f1bd3ac60b1a6a4783a3310e1f/Licenses/WEBRTC.md) has SHA-256
`d1f9382c6878ac024155fd6d44a5977329108bb8b0a01cea40e4a2f1d7de252e` and matches upstream Git blob
`f371735b3a706ff1401bce870f096efc9bbb5f51`.

The existing AboutLibraries module merge now links its complete, unchanged
UTF-8 Markdown text to `io.github.webrtc-sdk:android-prefixed:137.7151.04`,
preserving the original BSD reference. `android/config/SOURCES.json` records
the pinned file, hash and explicit heading population. The maintained graph
regression checks complete bytes, original license retention and missing,
substituted or unlinked text; the native notice guard pins the same digest.

This reference is separate from the empty Maven source JAR and packaging MIT
license. Its presence at the packaging tag and the earlier four-ABI byte
comparison do not prove that the notice was regenerated from the exact native
engine build or covers every linked component. Full native source/build
lineage, candidate-bound notice access, rights and recipient delivery remain
open. The previously tested APK is unchanged.


### JNA native source census preparation

At pinned JNA 5.19.1 revision
`1a91122853f6ab6f1fb2a4a284a6cf2ed8af0a4d`, all 449 blobs in the
`native/` subtree (2,997,685 bytes) were retrieved and matched against the
complete, non-truncated upstream Git tree. All 66 Java entries in the Maven
source JAR also match the corresponding Git blobs. Four upstream
`dist/android-*.jar` native libraries match the retained Maven AAR for
ARM64, ARMv7, x86 and x86_64. These are separate source and binary reference
comparisons; they do not prove which source/build invocation produced the
prebuilt libraries.

Private retained receipts in the existing dependency-source directory are
`jna-NATIVE-SOURCE-REFERENCE.json`, `jna-JAVA-SOURCE-REFERENCE.json`,
`jna-NATIVE-BINARY-REFERENCE.json` and `jna-SELECTED-NATIVE-HEADERS.json`.
The pinned Makefile lists dispatcher and callback objects and links libffi;
`native/README.libffi` identifies the latter as a source subtree.

A bounded inspection selected 38 dispatcher/header and libffi common,
include, ARM, AArch64 and x86 source files, excluding test suites. It includes
platform variants and is not an exact Android build-input list. Thirty-one
files have an identified first block comment containing copyright, license
or permission text, with 29 distinct complete blocks. Seven selected files
have no such identified comment. Preserve the detailed per-file results
instead of interpreting this lexical absence as a missing license.

These comments include copyright holders beyond the retained libffi root
LICENSE, including ARM, Oracle, CodeSourcery, Microsoft, Plausible Labs and
The Written Word. Reconcile the applicable source-file attribution with the
actual candidate build before claiming complete notices. The existing
collector now separately links `papercusp-jna-selected-native` to JNA alongside
the unchanged root libffi permission text. The supplement retains all 31
identified comments, grouping only the three identical AArch64 comments;
29 complete distinct blocks and all 38 source paths remain visible. It names
the seven unclassified files and preserves the platform-variant scope.

The complete supplement text has SHA-256
`fb64816cc17a4cabc50fd9ce09db1873d140cb6553119e06b7d22407b68be620`.
`android/config/SOURCES.json` pins the reference revision, selected-review
receipt digest and each source/header digest. The maintained metadata test
requires both JNA supplements, verifies identified/unclassified populations,
and rejects omitted files as well as missing, replaced or unlinked text.
The native resource guard pins the complete supplement fingerprint.

This is selected-source notice preparation. JNA's offered Apache/LGPL
alternatives, actual build-input/source lineage, final notice access and
recipient obligations remain open.

The existing source-archive command also prepares a selected JNA build/source
package from a local `jna-5.19.1-source` directory and the retained recursive
`jna-NATIVE-TREE.json` in the dependency-source output directory:

```sh
tools/build-scripts/android-release-provenance.sh source-archive jna
```

It reconstructs every upstream Git tree against root tree
`fc89bf9afa33183da9d35028855f6648b7a8b07b`, independently resolved from the
pinned commit. It verifies every selected blob, packages all `native/`, `src/`
and `ant-tools-src/` files plus eight root build/license files, and preserves
executable modes. The deterministic `papercusp-jna-source.tar.gz` contains its
per-file `SOURCE-PROVENANCE.json`; `papercusp-jna-source-result.json` records
the archive digest and producer/input fingerprints. A failure removes a prior
successful receipt. Maintained fixture tests reject eleven forms of changed,
missing, substituted or unsafe source/tree input.

The root Ant build generates JNI headers from Java sources and passes Android
architecture, JNI version/checksum and optional make overrides to the native
Makefile. Its `native-build-package` target is the upstream packaging route
for generated headers and a configured build script. The selected source
archive excludes prebuilt tool/library JARs and generated headers; a full
toolchain, chosen invocation and resulting dispatcher still require separate
verification. The native subtree includes tests and foreign architectures.
This preparation preserves both offered license texts and does not select
Apache versus LGPL or claim exact candidate inputs or recipient retrieval.

For recipient build preparation, use the pinned root `build.xml` route above.
Its `compile` target creates Java 8 classes and JNI headers through
`javac release="8"` and `nativeheaderdir`; the target named `javah` then
derives the JNI checksum from those headers. The separate
`native/build.xml` contains a legacy `javah` task and module properties;
it is not the same root build route. `common.xml` supplies dispatcher version
`7.0.4` and the expected checksum. Preserve these version and checksum inputs
when preparing a configured package.

The root build first compiles the Ant helper sources using `lib/ant.jar` and
`lib/asm-8.0.1.jar`. Both tool JARs are outside the selected source archive.
The retained upstream tree identifies them as Git blobs
`3bebb5c8836a49e3c572fbd678497bbf116555ff` and
`744fecc0252eb14db15e2cf76a7e0f3558c70ed8`, respectively. These are input
references, not verification that tools have been supplied to a recipient.

The inspected root Ant and native Makefile map the four application ABIs as
follows. These are supported source recipe mappings, not evidence of the
invocation that produced the cached dispatcher binaries.

| Application ABI | Ant `os.prefix` | Make `ARCH` |
|---|---|---|
| `armeabi-v7a` | `android-armv7` | `armv7` |
| `arm64-v8a` | `android-aarch64` | `aarch64` |
| `x86` | `android-x86` | `x86` |
| `x86_64` | `android-x86-64` | `x86-64` |

The Makefile defaults to NDK r10e's GCC tools and Android 21 platform sysroots;
it already specifies 16 KB maximum and common linker page sizes. Ant passes
`EXTRA_MAKE_OPTS` as make overrides. Do not substitute the application's
current NDK and infer that this upstream recipe works unchanged. Before
claiming a buildable recipient package, supply and fingerprint its actual
Java/Ant/ASM and native toolchain, execute the configured upstream route,
retain generated headers and build-script inputs, and verify the resulting
dispatcher and recipient retrieval against the exact candidate. The original
prebuilt invocation and license election still require their own evidence.

The existing provenance command can independently consume that retained
package and its reference receipt without rebuilding or re-exporting it:

```sh
tools/build-scripts/android-release-provenance.sh source-verify-build jna-inputs
# An independently obtained package directory may be passed as the third argument.
```

This offline check validates the archive digest, complete per-file population,
SHA-256/Git blob identities, embedded provenance and required build/license
inputs against the pinned root reconstructed from the retained recursive
`papercusp-android-dependency-sources/jna-NATIVE-TREE.json` sidecar. That
sidecar is an additional input, not part of the earlier selected archive;
even a self-consistently changed archive/receipt cannot substitute new blobs.
It checks the root Java-release/header-generation and JNI
version/checksum recipe. The existing source ledger pins both excluded helper
JARs. If `lib/ant.jar` or `lib/asm-8.0.1.jar` is supplied beside the archive,
its size and Git blob must match; otherwise the result explicitly lists it as
missing. Symlinks, special archive members, changed/substituted inputs and
stale successful results are rejected by maintained tests.

`papercusp-jna-build-inputs-result.json` distinguishes supplied tool bytes
from missing prerequisites and always records that no build, standalone
toolchain validation, original invocation verification or recipient retrieval
was performed. A successful local input check is not a buildable-package,
license-clearance or publication claim. Actual recipient retrieval/build,
generated inputs, original invocation and exact-candidate comparisons remain
required.

The existing source consumer also supports local upstream configured-package
preparation, using the same retained archive and pinned recursive tree:

```sh
JAVA_HOME=/path/to/jdk ANT_HOME=/path/to/ant \
  tools/build-scripts/android-release-provenance.sh source-verify-build jna-configure
```

Supply the two pinned helper JARs beside the archive and the four root
`pom-jna*.xml` templates. The consumer verifies each template against its
original tree blob. `ANT_HOME/lib` must contain the source-ledger-pinned Ant
1.10.15 core and launcher JARs (versioned or ordinary names); Java and Ant
versions and actual executable/JAR fingerprints are retained. This modern
Ant execution runtime is separate from the upstream pinned `lib/ant.jar`
used to compile helper sources.

In a fresh local directory the command runs the unmodified upstream root
`native-build-package` target for the four application ABIs. It compiles Java
8 classes and JNI headers, checks the generated JNI version/checksum, and
verifies the generated script, headers and native source bytes in each
configured ZIP. Its census records Ant's explicit and default exclusions,
including omitted `config.guess`, `config.sub`, `.gitignore` and
`.gitattributes`; required hidden source files remain included. These upstream
ZIPs are configured subsets of the retained full selected source package,
and their omitted files remain available in that original package. The command
retains per-ABI logs and ZIPs and writes a separate
`papercusp-jna-configure-result.json`; the earlier input-only result is
preserved. It never runs the generated script or compiles a native dispatcher.
This prepares configured build inputs locally. Native compiler/sysroot
validation, dispatcher compilation, original prebuilt invocation, license
election, complete source/notice rights, exact-candidate comparison and actual
recipient retrieval/build remain required.

The retained configured ZIPs can now be consumed by the same provenance tool
without repeating Ant preparation:

```sh
ANDROID_NDK_HOME=/path/to/android-ndk/27.0.12077973 \
  tools/build-scripts/android-release-provenance.sh source-verify-build jna-native
# Optional third argument: retained package directory; fourth: all or one app ABI.
```

The Linux host requires GNU make, autoreconf, autoconf, automake, aclocal,
autoheader, libtoolize, m4, Perl, texinfo's `makeinfo`, sed, awk, grep and patch.
On Ubuntu these are provided by `build-essential autoconf automake libtool
m4 perl texinfo patch`; the maintained preflight checks every executable before
native make and records its version and SHA-256. Documentation is built normally;
`MAKEINFO=true` is not a supported substitute. The NDK revision, API 24 sysroot,
JNI headers and each selected Clang/binutils executable are checked and retained.

The consumer validates each ZIP against the pinned native-source population and
retained generated script/header fingerprints, then uses a fresh per-ABI directory.
It invokes the upstream Makefile's dispatcher target directly: the generated script
does not reliably propagate a failed make exit. Dispatcher link/output flags are
cleared for libffi configure and excluded from recursive make; include paths are
absolute. Each attempt retains its command, build log and result, including failures.
Successful output must be a shared little-endian ELF for the selected ABI with
16 KB aligned LOAD segments, the JNI version/checksum and required JNI exports.
`papercusp-jna-native-result.json` is written only after that validation and current
source/input checks. The two earlier failed ARM64 attempts remain separate evidence.

This command proves local compilation only for its listed ABIs. It does not execute
the dispatcher or establish the original prebuilt invocation, license election,
complete source/notice rights, exact-candidate equivalence or recipient retrieval.
Those release requirements remain open.

### JNA distribution license choice

For Android release preparation, Papercusp selects **Apache-2.0** for the
JNA 5.19.1 portions covered by the upstream alternative grant. The root
`LICENSE` expressly permits this choice, as do the retained `dispatch.c`
and `callback.c` headers. This selects one offered grant; it does not relicense
libffi, other third-party code, the mobile application or separately delivered
build/test tools. Preserve the original Apache/LGPL offer and source notices.

The October 3 read bound the grant to these retained inputs without rebuilding
the APK or dispatcher:

| Input | Verified identity |
| --- | --- |
| Resolved JNA 5.19.1 AAR | SHA-256 `b57125cb7d16253f0d65a80f7d3a4c3664effa711b8bdbb7f87fb572ce1624ed`; equals the retained exported-debug build's `debugRuntimeClasspath` inventory. |
| AAR `classes.jar!/META-INF/LICENSE` | SHA-256 `07c938b23950ab7d47a24ef35f9f5da3a05ae164278dc959ad6994135ed59ff1`; byte-identical to the pinned JNA root `LICENSE`. |
| Pinned root `LICENSE` | Git blob `9d95afbeb58a153669393e633af39b48fd4ca94c`, at revision `1a91122853f6ab6f1fb2a4a284a6cf2ed8af0a4d`. |
| Pinned `AL2.0` | Git blob `f433b1a53f5b830a205fd2df78e2b34974656c7b`; SHA-256 `0d542e0c8804e39aa7f37eb00da5a762149dc682d7829451287e11b938e94594`. |
| Pinned `LGPL2.1`, retained as offered | Git blob `3b204400cf3d548f93a0f4f8e85d41d7e39ecb59`; SHA-256 `eea173a556abac0370461e57e12aab266894ea6be3874c2be05fd87871f75449`. |

The final signed candidate must independently match the resolved JNA version,
artifact and grant before this choice is applied to its distribution. Deliver
the complete Apache-2.0 text, retain applicable copyright/attribution and any
upstream NOTICE, and identify modifications if any. The existing collector's
original Apache/LGPL labels remain reference metadata; this packet records
Papercusp's choice. The selected libffi permission text and per-file attribution
remain separate obligations. The retained `native/libffi/LICENSE-BUILDTOOLS`
also distinguishes separately licensed build/test helpers from libffi itself;
shipping source tools requires preserving their own grants and notices.

This resolves the preparation choice for the verified JNA alternative grant.
It does not establish the prebuilt dispatcher's original invocation, complete
third-party rights/notices, account entitlements or final-candidate acceptance.
Earlier source/archive/build receipts keep their original no-election scope.

### Recipient source delivery acceptance

Use the existing release-provenance and source-verifier surfaces for the final
delivery. Local outputs and private repository URLs remain preparation only.
Before claiming corresponding-source delivery complete:

1. Bind the signed candidate's source commit and exact APK/AAB identities to
   the root source archive, recursively pinned token-kit source, applicable
   dependency sources/notices and required build instructions/tool inputs.
   Preserve separate license grants for source and build/test components.
2. Make the applicable source package available through the actual supported
   recipient-accessible destination, recording its URL and archive digests.
   A private cache, local path or operator-authenticated download is insufficient.
3. Retrieve the package with the recipient's permitted access, without private
   repository credentials or the developer's dependency cache. Record the
   retrieval result and compare the retrieved bytes with the candidate-bound
   manifest; retain unavailable or omitted inputs as explicit failures.
4. Compile the retrieved inputs through the existing source verifier in a fresh
   build directory. Supply and fingerprint its real prerequisites, including
   the pinned Ant/ASM helpers and NDK when exercising the JNA source route.
   Do not substitute a local successful build for this recipient build.
5. Verify the final candidate's notice access and packaged populations, then
   retain the candidate, delivery, retrieval and build evidence together.

No recipient destination, publication, retrieval or recipient build is claimed
by this preparation update. Provider/reviewer journeys, current hosted CI,
physical-phone and Play acceptance remain required.

### WebRTC packaging and engine-version references

The October 3 static read confirms that the pinned Android publication
workflow downloads `libwebrtc_prefixed.aar`, shadows its Java package and
renames the native library before Maven publication. That workflow
packages a prebuilt engine; it does not compile the engine itself.

The retained GitHub release AAR SHA-256
`76b7fc94ac3a16b81bd42f0e8bf781636ad52f815d296f1c0c314271fd1ed262`
equals the digest published for the `v137.7151.04` asset. Its
`classes.jar!/org/webrtc/WebrtcBuildVersion.class` and the resolved Maven
AAR `07934f87e0c3897fd8107f9193eda0f35007c3aee92b4e085b909ed0fe3fd66c`
both carry these configured values:

| Version-class field | Retained value |
| --- | --- |
| `webrtc_branch` | `M137` |
| `webrtc_commit` | `07` |
| `webrtc_revision` | `f4967efc183c371ff984632f8909ba022ee275cd` |
| `maint_version` | `0` |

In the Maven AAR, the class is in
`libs/shadow-all.jar!/livekit/org/webrtc/WebrtcBuildVersion.class`; its
top-level `classes.jar` has no entries. Inspect nested JARs before making
a missing-class or version claim.

The builder's `m137.7151.07` tag at
`fd0db0bb3982a48b67ffb436b266492f90a4fda8` has matching `build/VERSION`
values. By contrast, its same-number `m137.7151.04` tag at
`bc119640a2c675e5baaa7a1c661d0cb5264e1a14` defaults to
`e13f18f31a1c029af76682dbe99d5c47ff99b8b9`. These are reference
comparisons, not proof that the engine was compiled from either checkout.

The inspected writer derives `webrtc_commit` from the third dotted version
component; it is not a Git commit ID. `webrtc_revision` comes from the
configured `VERSION` file. The build accepts a separate `--commit`
override for the actual source checkout, so even a matching Java marker does
not prove native source lineage. The package producer writes actual checkout
URLs and revisions to `VERSIONS`, and generates `NOTICE` using the
engine's license generator and selected GN build outputs. The following
package read supplies those records and a bounded binary relationship.

The existing private dependency-source directory retains
`webrtc-BUILD-SOURCE-REFERENCE.json`: selected packaging/build source
snapshots, their upstream Git-blob and SHA-256 identities, the two AAR
identities, exact class constants and the writer interpretation. The snapshots
were checked against non-truncated pinned upstream trees. They do not supply
the full engine/dependency source census or regenerate its notice bundle.

Preserve the earlier four-ABI byte comparisons and complete packaging notice
reference in their original scope. Original native invocation, applied patches,
complete source/notice rights, final-candidate notice access and actual
recipient retrieval/build remain open. No build or test proof was replayed.

### Retained WebRTC build-package records

The published builder package for `m137.7151.07` was retrieved on October 3
from its [release asset](https://github.com/webrtc-sdk/webrtc-build/releases/download/m137.7151.07/webrtc.tar.gz).
Its 254,047,798 bytes match the published SHA-256
`4cb17d2def413114edbe7e5192cb67d3b614d64a2aa34f6d47fcc6884de731e8`.
The private dependency-source directory retains the archive as
`webrtc-m137.7151.07.tar.gz`, its raw `webrtc/VERSIONS` and `webrtc/NOTICE`,
and their inventory in the existing `webrtc-BUILD-SOURCE-REFERENCE.json`.

The archive's `webrtc/aar/libwebrtc.aar` has SHA-256
`d1b30fc546c1e3d868a1a5df28e0e4e434f2299bec2b218955d77d5305c2adf3`,
which differs from the retained Android release AAR's ZIP hash. Both have
exactly the same six entry names, with identical uncompressed bytes for
the manifest, `classes.jar` and all four native libraries. Their ZIP
timestamps differ. This binds the package payloads to the earlier retained
Android asset by bytes; it is not a fresh compilation or a source-to-binary
reproduction.

The raw `VERSIONS` has SHA-256
`c34f6fb059775ebd52a8dba0ce8ef0a48a765bb246039e99be112054d706fab8`.
Its actual checkout records report:

| Checkout | Recorded revision |
| --- | --- |
| WebRTC engine, `https://github.com/webrtc-sdk/webrtc.git` | `f4967efc183c371ff984632f8909ba022ee275cd` |
| Build, `https://github.com/webrtc-sdk/build` | `01021e6c12636951a6b4e5342e16b2101b352367` |
| Chromium buildtools | `0f32cb9025766951122d4ed19aba87a94ded3f43` |
| libc++ | `917609c669e43edc850eeb192a342434a54e1dfd` |
| libc++abi | `f2a7f2987f9dcdf8b04c2d8cd4dcb186641a7c3e` |
| libunwind | `81e2cb40a70de2b6978e6d8658891ded9a77f7e3` |
| Chromium third_party | `8062e0e102496ff14a8c58b586f014527424953d` |
| Chromium tools | `ffcbc837bbb14d80d09147c2af5302ff6bd4bd69` |

The producer copies `VERSION` and appends checkout records without inserting
a newline. In this package, configured `WEBRTC_COMMIT` and `WEBRTC_SRC_URL`
are concatenated on one line; the source URL above is explicitly read from
that suffix. Preserve the raw text and do not treat that line as two ordinary
key/value rows. The separate `WEBRTC_SRC_COMMIT` row supplies the recorded
engine checkout. These records do not establish clean checkout contents,
applied patches or every fetched dependency revision.

Four Git-blob-checked source snapshots from the reported engine revision
are retained in that same private reference: `LICENSE`, `PATENTS`, `DEPS`
and `tools_webrtc/libs/generate_licenses.py`. The seven non-engine Git
revisions listed above match the corresponding literal `DEPS` declarations.
The generator maps each of the notice's 36 section names to retained source
license paths. Its dependency discovery reads the selected GN targets and
build directories, so those static mappings alone cannot regenerate the
notice or establish which dependencies were actually fetched. The source
files were inspected as data; their code and hooks were not executed.

The complete generated `NOTICE` is 216,282 bytes, SHA-256
`e7edab7dadf71c78b6c408e712a1c1b2bfc8a1f358faa787f69844c89b21e957`.
Its 36 sections include WebRTC, BoringSSL, dav1d, FFT routines,
libaom, libc++, libsrtp, libvpx, libyuv, Opus, protobuf and other
generator-selected components. The raw text includes HTML entities;
preserve it when preparing readable distribution notices. Retaining this
notice does not prove that the final candidate delivers it or establish
distribution rights for every component.

The complete archive file census contains 45,512 `.h` files, 1,045 `.hpp`
files, four static libraries, one AAR, one JAR and the two records above.
It supplies headers and binaries, with no implementation files from the
inspected C/C++/Java/Kotlin/Rust/script suffixes. It does not deliver the
full corresponding engine/dependency source or original build invocation.
Complete sources and patches, source-to-binary reproduction, final notices,
recipient delivery/build and every existing signed-candidate/provider/reviewer/
hosted-CI/physical-phone/Play requirement remain open.

### Retained WebRTC engine and builder implementation sources

The private dependency-source directory now also retains the pinned repository
source archives below. This supplements the header/binary build package; it
does not include external dependency checkouts or establish corresponding-source
delivery for the final candidate.

| Repository source | Revision | Archive SHA-256 | Verified files |
| --- | --- | --- | --- |
| WebRTC engine | `f4967efc183c371ff984632f8909ba022ee275cd` | `994c4575917a4589756d92e2a3de7a93c69e981387f4d41e11597112576c2b9c` | 7,368 |
| WebRTC builder | `fd0db0bb3982a48b67ffb436b266492f90a4fda8` | `09a5cdf2b433260b851228092bcf5f9186cb2a49d7556c6b3e01f461360ce577` | 68 |

The files are `webrtc-engine-f4967efc-source.tar.gz` (40,084,452 bytes) and
`webrtc-builder-fd0db0bb-source.tar.gz` (51,971 bytes). The existing
`webrtc-BUILD-SOURCE-REFERENCE.json` records every source path, Git blob,
SHA-256, size and mode. Every archive file matched the complete, non-truncated
pinned Git tree; path-set equality, unique safe paths and executable/symlink
modes passed. Archive readback hashes also passed. Source was inspected as data.

The pinned builder's `android_prefixed` recipe lists, in order,
`add_license_dav1d.patch`, `android_webrtc_version.patch`, `fix_mocks.patch`
and `jni_prefix.patch`. All four patch texts, `.gclient` and the package-install
script are retained with their blob and content fingerprints. The recipe
applies each patch with `-p1` after `gclient sync`. The JNI-prefix patch also
changes files under external `third_party/jni_zero`; the engine repository
archive alone therefore cannot supply all patch inputs.

The repository-retention preparation above executed no patch, upstream script,
hook, compiler or native payload. The separate target-only patch preparation
below applies the four retained patches to isolated source data. External
DEPS/CIPD sources and tool inputs, the complete applied
checkout, generated version source, original GN arguments/output and source-to-binary
reproduction remain required. Complete final notices/rights, exact signed-candidate
binding and actual recipient retrieval/fresh build remain open, alongside every
existing provider/reviewer/hosted-CI/physical-phone/Play requirement.

### Retained external JNI-prefix patch inputs

The pinned engine's `DEPS` selects `src/third_party` revision
`8062e0e102496ff14a8c58b586f014527424953d`, which also matches the retained
build package's `VERSIONS` record. The private
`webrtc-jni-zero-8062e0e1-source.json` now retains the complete pristine texts
of all four `third_party/jni_zero` files identified by the `---`/`+++` hunk
paths in `jni_prefix.patch`. Two `diff --git` headers omit `third_party`;
the earlier two-target coverage claim is corrected here.

| Patch input | Git blob | Source SHA-256 |
| --- | --- | --- |
| `BUILD.gn` | `31a6f3d6b9a9c973bebf68b7f6af42180442e16a` | `409bacfd1f649db582f075b60645700303d46df7eb0e8fd9608aba9eac49baea` |
| `codegen/header_common.py` | `e401549e5519bd0555dca109a046e8be3d34cd4f` | `38b22fb5dc37a30fbef5a80049c5a586709b92d4bc01dd0e6d759fda0d302b0c` |
| `jni_zero.gni` | `31c1392fad4873cf49594cbb3d2a8987d6911c1e` | `ac2f533d6698f4a10bb9b3c3f72337706cca1f899b7b0b86427c7c35d405bcec` |
| `parse.py` | `9195137abec229257444f96813fee9b1d86fecea` | `10af81a7b58aef221eb810adcfe4068726b5a5a51cbe2920cd5721991a6ff846` |

Their complete Git blob identities match the patch's old-index prefixes.
Readback checked each text's size, SHA-256 and Git blob identity, and verified
that these four paths exactly cover the patch's external JNI-zero hunk targets.
The receipt SHA-256 is
`df5ec0fe6ae81aee98a30e3e2865f41a84febf55fae0b56b77746a95b17a3580`;
the existing private build-source reference binds that receipt.

The earlier attempts stopped on HTTP 429 and HTTP 503. On 2026-10-05 the
resume first rehashed all 33 cached directory-tree objects and checked their
parent-child links. The resulting complete path set contains 185 source files.
All 13 retained files passed their pinned blob, path, mode, size and SHA-256
checks before they were reused. The attempt retained 62 additional verified
files: 75 are now cached and 110 remain missing. The four patch inputs above
remain byte-for-byte unchanged.

The tree cache is `webrtc-jni-zero-8062e0e1-trees.json`, SHA-256
`725bb259b618f86c44937ecbf36bdf0611b0616e9b10a988f088d08747d13f0c`. The blob cache is
`webrtc-jni-zero-8062e0e1-blobs.tar`, SHA-256
`47aaaa86c68964a391c703ef376addb72591486eb6f56ceb1037365e94c40455`. Readback checked all 75
unique tar members against the complete pinned tree and progress fingerprints.
The progress sidecar, SHA-256
`039ccb7fedf073ffba9068e60bcae68471f6620ae55c9456cf923e310560bb72`, preserves prior attempts and
records the reused and newly retained files without redownloading settled data.

Acquisition stopped at `sample/javatests/AndroidManifest.xml` on HTTP 503 at
2026-10-05T15:13:31Z; the response supplied no `Retry-After`. No automatic retry
was performed. Full-subtree source retention and source archive creation remain
false. Preserve the cache and honor upstream retry/backoff signals before
resuming the missing files; independent dependency/tool input preparation can
continue. Other external DEPS/CIPD sources, applied-source verification, build
reproduction, final notices/rights, exact-candidate, recipient and existing
release requirements remain open. No upstream script, hook, patch, compiler
or native payload was executed.

### Retained pinned WebRTC build dependency source

The engine DEPS and retained package VERSIONS both select `src/build` from
`webrtc-sdk/build` at `01021e6c12636951a6b4e5342e16b2101b352367`. This is
the build dependency used by the engine; the separate builder repository
above supplies the packaging recipe. The private archive
`webrtc-build-01021e6c-source.tar.gz` contains 1,359 verified source files
and is 1,666,356 bytes, SHA-256
`71df114a33c8ad4600ed4302c610f9de776147fe33d030f5e8bb16323469a9f8`.

All 274 directory trees match recomputed Git tree identities. Every unique
safe archive file matches the complete pinned blob path set, Git blob, size,
SHA-256 and executable semantics; the tree is not truncated and has no gitlinks.
The GitHub archive transports regular files as `664`/`775`, while Git records
`100644`/`100755`. The receipt records both modes separately and accepts only
those measured group-write differences, preserving executable/type checks.
Archive and receipt readback passed. The private per-file/tree census is
`webrtc-build-01021e6c-source.json`, SHA-256
`0810a3c2352bda3b4b68285a29bbde937ad5bf2adf27c8134c6992522556105b`; the existing build-source
reference binds both artifacts.

This is pristine dependency-source preparation. It does not establish the
actual applied checkout, original toolchain/invocation, source-to-binary
reproduction, remaining dependency inputs, final notices/rights, exact signed
candidate, recipient retrieval/build or release acceptance. The incomplete
JNI-zero cache remains 75 of 185 files. No upstream code was executed.
### Retained pinned BoringSSL dependency source

The engine DEPS selects `src/third_party/boringssl/src` at
`34492c89a8e381e0e856a686cc71b1eb5bd728db`. The official
`google/boringssl` repository resolves that exact commit. The private archive
`webrtc-boringssl-34492c89-source.tar.gz` retains all 7,908 repository files:
46,149,400 bytes, SHA-256
`61f9abae8ccc7a3d0aa27db97364ab6187383441c8d11dfe315065cd612c5e8f`.

All 405 directory trees match recomputed Git identities, including root
`0a279b3e9398d5ec0b3fb0906e991a839076649f`. The tree is complete and has no
gitlinks. Every unique safe archive file matches the pinned blob path set,
Git blob, size, SHA-256, type and executable semantics. The receipt records
Git and archive modes separately, accepting only the measured GitHub
`664`/`775` group-write variants. Independent archive readback passed.
The complete per-file/tree receipt is `webrtc-boringssl-34492c89-source.json`,
SHA-256 `53c26a387c461ffe292d8b15546af9a6f96dbedc7eead0cabae0a05edacdfb44`;
the existing private build-source reference binds both artifacts.

This pin comes from engine DEPS; the retained package VERSIONS does not
report a separate BoringSSL checkout. Pristine repository retention does not
establish the actual applied source, fetched dependency closure, original
GN/toolchain invocation, source-to-binary reproduction, final notices/rights,
exact signed candidate, recipient retrieval/build or release acceptance.
No upstream code was executed.

### Incomplete pinned buildtools tree preparation

Engine DEPS and package VERSIONS both select buildtools at
`0f32cb9025766951122d4ed19aba87a94ded3f43`. Seven directory-tree records are
cached with recomputed Git identities and parent-child bindings, including
root `9166807a6c651c3382e5b89ccf1cde5adb0f7749`. Directory enumeration
stopped at `reclient_cfgs/linux_chroot` on HTTP 503 at
`2026-10-05T15:38:50.462837+00:00`, with no Retry-After response header.
The failed request was not retried.

The partial receipt is `webrtc-buildtools-0f32cb90-source.json`, SHA-256
`f31c0811f82f124861a61f7996764c2dbdfd8990be5703e2a77ea96fb40ae753`.
Its tree cache is `webrtc-buildtools-0f32cb90-trees.json`, SHA-256
`89dbffa8d6c0438c8b3794dda84789c56a371afcf1f98280b61540532e65eb69`.
No source blobs were retained; the 10,240-byte tar is empty. The receipt
explicitly marks complete tree enumeration and source retention false.
The existing source reference records this as pending preparation. Preserve
this cache and upstream backoff; the JNI-zero cache remains 75 of 185 files.
Binary tools and the other existing release requirements remain open.

### Retained pinned Libvpx dependency source

Engine DEPS selects `src/third_party/libvpx/source/libvpx` at
`ff1d193f4b9dfa9b2ced51efbb6ec7a69e58e88c`. The `webmproject/libvpx`
repository resolves that exact commit. The private archive
`webrtc-libvpx-ff1d193f-source.tar.gz` retains all 1,245 repository files:
5,627,705 bytes, SHA-256
`69dd79503f4d2a497a3e52d0f8679d7539b4bc4c019b8787edd8d620366505a6`.

All 85 directory trees match recomputed Git identities, including root
`e0323714cad9d5b0541b92e08d780e47c9a4fc35`. The tree is complete and has no
gitlinks. Every unique safe archive file matches the pinned blob path set,
Git blob, size, SHA-256, type and executable semantics. Git and archive modes
are recorded separately; only the measured GitHub `664`/`775` group-write
variants are accepted. The persisted archive passed a second full readback.
The complete per-file/tree receipt is `webrtc-libvpx-ff1d193f-source.json`,
SHA-256 `389f39ce8237606657dce722fcc1a94f4d9233af817edd39d91b37bc934b265a`;
the existing private build-source reference binds both artifacts.

This selection comes from engine DEPS. The retained package VERSIONS does
not report a separate Libvpx checkout. Pristine source retention does not
establish applied source, dependency closure, original GN/toolchain
invocation, source-to-binary reproduction, final notices/rights, exact signed
candidate, recipient retrieval/build or release acceptance. No upstream code
was executed. The incomplete JNI-zero and buildtools caches are unchanged.

### Retained pinned dav1d dependency source

Engine DEPS selects `src/third_party/dav1d/libdav1d` at
`8d956180934f16244bdb58b39175824775125e55`. VideoLAN's read-only GitHub
mirror, `videolan/dav1d`, resolves that exact commit. The private archive
`webrtc-dav1d-8d956180-source.tar.gz` retains all 359 repository files:
1,712,974 bytes, SHA-256
`58550122e4d171eac403f4b277a40443f25c05e8d180b9eb971e6f039be04297`.

All 35 directory trees match recomputed Git identities, including root
`50933961732d02da827cbd7f183903afd17be118`. The tree is complete and has no
gitlinks. Every unique safe archive file matches the pinned blob path set,
Git blob, size, SHA-256, type and executable semantics. Git and archive modes
are recorded separately; only the measured GitHub `664`/`775` group-write
variants are accepted. The persisted archive passed a full readback.
The complete per-file/tree receipt is `webrtc-dav1d-8d956180-source.json`,
SHA-256 `4a922c2ef5e697e8dc785945d7b16e67fb16db983f2eb682f4c4888e5054310d`;
the existing private build-source reference binds both artifacts.

This selection comes from engine DEPS. The retained package VERSIONS does
not report a separate dav1d checkout. Pristine source retention does not
establish applied source, dependency closure, original GN/toolchain
invocation, source-to-binary reproduction, final notices/rights, exact signed
candidate, recipient retrieval/build or release acceptance. No upstream code
was executed. The incomplete JNI-zero and buildtools caches are unchanged.

### Verified Android-prefixed patch targets

The four retained builder patches were applied in their recorded order to
exactly 14 original source targets: ten files from the pinned engine and four
from the pinned external JNI-zero revision. Original bytes, Git blob identities,
SHA-256, sizes and executable modes matched the retained source receipts.
GNU patch applied each patch with `-p1`, zero fuzz and a successful dry run.
The receipt records line offsets. The original `add_license_dav1d.patch` lacks
a final newline; its exact retained bytes were used and its warnings preserved.

The bounded verifier additionally uses batch/forward mode and suppresses
mismatch backup files. These are verifier choices; the original builder recipe
records `patch -p1`. Reversing the four patches in reverse order restored every
original target's exact bytes and modes. No upstream script, hook, compiler or
native payload was executed, and the temporary data directory was removed.

The private before/after bundle contains 32 files: 14 originals, 14 patched
targets and four original patch texts. It is
`webrtc-android-prefixed-patch-preparation.tar.gz`, 95,773 bytes, SHA-256
`8910dfcee78b18aa4d32d11693a3a13c808022fc7d28b9d7888c04ea044b27e2`.
Its receipt is `webrtc-android-prefixed-patch-preparation.json`, 30,043 bytes,
SHA-256 `58c405be8958ddd44daabb54f6648e16b1cf584e859532150da10ab16ac208df`.
Persisted archive readback checked the exact unique safe path set, file types,
bytes, modes, sizes and fingerprints. The existing build-source reference binds
both artifacts under `implementationSourcePreparation.patchApplicationPreparation`.

This verifies the patch targets. It does not supply the complete dependency
checkout, generated `WebrtcBuildVersion.java`, original GN/toolchain invocation
or source-to-binary reproduction. Final notices/rights, exact signed candidate,
recipient retrieval/fresh build and every existing release requirement remain open.
The JNI-zero and buildtools caches are unchanged. Separate LSS blob and libyuv
archive acquisition attempts returned HTTP503 without source retention; the
private reference records these attempts and they were not automatically retried.

### Pinned generated WebRTC version source

The separate private generated-source preparation retains
`sdk/android/api/org/webrtc/WebrtcBuildVersion.java` from builder
`fd0db0bb3982a48b67ffb436b266492f90a4fda8`. The pinned `build/run.py`
writer and `build/VERSION` were read as data; no upstream module was imported
or evaluated. The output preserves all seven UTF-8 lines and their final LF.
Its four labels are `M137`, `07`,
`f4967efc183c371ff984632f8909ba022ee275cd`, and `0`.
Reading the retained upstream AAR class's String `ConstantValue` fields as
data confirmed these same four values without loading or executing the class.

The source is 313 bytes, SHA-256
`1af18e1951d3be5a2269389da6faaacd95ae1fc5b59473297e5855051e15af5e`,
at `webrtc-generated-version-fd0db0bb/sdk/android/api/org/webrtc/WebrtcBuildVersion.java`
under the existing private dependency-source directory. The receipt
`webrtc-generated-version-fd0db0bb.json` is 5,273 bytes, SHA-256
`78ef0729914c9fc2de4662bd3d1e2033998f93ed534e2e7f53ee4d07f0ab4260`.
It binds both pinned builder inputs, the package VERSIONS prefix, the source
and the retained AAR/class fingerprints. Readback verified exact bytes, size,
Git blob and separately recorded filesystem/executable semantics. The existing
build-source reference binds both files under
`implementationSourcePreparation.generatedVersionSourcePreparation`.

The builder VERSION lacks a final newline; the package writer copies those
155 bytes before appending checkout records. Derivation therefore reads the
complete builder VERSION rather than treating the concatenated package line
as a separate version value. Leading zero in `07` is preserved.

This prepares generated source and compares configured labels. The builder
can override its checkout commit independently of those labels, so agreement
does not prove implementation identity or binary reproduction. The complete
applied checkout, remaining DEPS/CIPD/tools, original GN/toolchain invocation,
final notices/rights, exact signed candidate, recipient retrieval/fresh build
and release acceptance remain open. Existing source/patch archives and the
incomplete JNI-zero/buildtools caches are unchanged.

### Retained pinned RE2 and byte-exact JSONcpp sources

Engine DEPS selects `src/third_party/re2/src` at
`c84a140c93352cdabbfb547c531be34515b12228` and
`src/third_party/jsoncpp/source` at
`42e892d96e47b1f6e29844cc705e148ec4856448`. Their exact upstream GitHub
commits and complete recursive trees were retained before archive acquisition.
Neither repository has gitlinks. This supplements the existing source preparation.

| Source | Blobs / directory trees | Exact source archive bytes | Archive SHA-256 |
| --- | --- | --- | --- |
| google/re2 | 136 / 14 | 391,028 | `94ad73bd2b32177874239bbb0a59625901212252751518c27f87f78d191c36ad` |
| open-source-parsers/jsoncpp | 252 / 22 | 212,411 | `c852fdfdf5fc80b5169969f99fba7d4810c7d979c91799946b62b87a64543c03` |

RE2 is retained as `webrtc-re2-c84a140c-source.tar.gz`, with receipt
`webrtc-re2-c84a140c-source.json` (89,008 bytes, SHA-256
`238181d7641d957ad12dd333382e5b213a8e42a131bab5dd300efa117177e787`).
Its reconstructed root Git tree is
`aac1c2111623d62bd280fb5ac62662c96d8e4716`.

JSONcpp's original codeload archive has the complete path set, but its retained
`.gitattributes` selects CRLF for `devtools/agent_vm*`. Two JSON files differ
from their Git blobs: `agent_vmw7.json` is 898 rather than 865 bytes, and
`agent_vmxp.json` is 589 rather than 563 bytes. Fetching their exact pinned Git
blobs established that LF-to-CRLF conversion accounts for each entire difference.
The original archive remains separate; it is not byte-exact Git source.

`webrtc-jsoncpp-42e892d9-git-source.tar.gz` supplies all 252 original Git blobs:
250 unchanged codeload entries and the two verified raw Git blobs. It was
assembled deterministically as data, with Git executable/symlink semantics.
`webrtc-jsoncpp-42e892d9-git-blobs.json` retains those two original blobs and
the distinguishing comparison (SHA-256
`b5360c0b7af23ebc201960798ee3722507310e8184524c92eedbe0f80b7b51e1`).
The receipt `webrtc-jsoncpp-42e892d9-source.json` is 176,550 bytes, SHA-256
`3e793b49e9359bc441b99c9ec97d5f24e47dec4e82139f2719b63b82d36ab911`;
its reconstructed root is `c9b5ffc95a60647ddfba8a148daa86d0235df093`.

Persisted archive readback and a second independent offline reconstruction
verified complete safe unique blob/directory path sets, every Git blob/tree
identity, size, SHA-256, type and executable semantics. The existing
`implementationSourcePreparation.sources` binds these archives, receipts and
the JSONcpp original-download/supplement distinction. No upstream code was
executed. Original GN selection, remaining DEPS/CIPD/tool inputs, the complete
applied checkout, original toolchain/invocation and native reproduction remain
open, alongside final notices/rights, exact signed candidate, actual recipient
retrieval/fresh build and release acceptance. Chromium's CRC32C GN wrapper
remains unretained. A read-only Cisco libsrtp GitHub lookup returned 404 for
the exact Chromium DEPS pin; no libsrtp source was acquired or retried.

### Retained pinned Android cpu_features dependency source

Engine DEPS selects `src/third_party/cpu_features/src` for `checkout_android`
at `936b9ab5515dead115606559502e3864958f7f6e`. Google's upstream
`google/cpu_features` repository resolves that exact revision. The private
archive `webrtc-cpu-features-936b9ab5-source.tar.gz` retains all 100 blobs:
102,400 bytes, SHA-256
`851c2f0b1e31b0d3a5389ba5df1850e27670fd7c09c8fa1d1ae322d6035135d2`.

All 21 directory trees match recomputed Git identities, including root
`4a71426165971ad8be17aaee8a497c5a1ad1aecb`. The recursive tree is complete
and has no gitlinks. The exact unique safe archive blob and directory path
sets, Git blobs, sizes, SHA-256, types and executable semantics passed.
Git modes and raw GitHub archive modes are recorded separately. Persisted
archive readback and a second independent offline reconstruction passed.
Metadata was retained before archive acquisition so a later failure would
preserve the measured commit, complete tree and dependency selection.

The receipt `webrtc-cpu-features-936b9ab5-source.json` is 72,023 bytes,
SHA-256 `d4fc74f102aaedc41a3e304b542bd91ded922e2dd512b662a46399a3b4e4a3cd`.
The existing private build-source reference binds both artifacts and the
engine DEPS selection. This prepares pristine dependency source. Complete
applied checkout, remaining DEPS/CIPD/tools, original GN/toolchain invocation,
native reproduction, final notices/rights, exact signed candidate, actual
recipient retrieval/fresh build and release acceptance remain open. No upstream
code was executed. Existing archives and incomplete caches are unchanged.

### Retained pinned crc32c repository blobs and submodule boundary

Engine DEPS selects `src/third_party/crc32c/src` at
`d3d60ac6e0f16780bcfcc825385e1d338801a558` in Google's upstream repository.
The private archive `webrtc-crc32c-d3d60ac6-source.tar.gz` retains every one
of its 37 repository blobs: 29,851 bytes, SHA-256
`37f7e216fd39a60e8e05d7e4301a934cc4857fc0fbd9a14aa72ec4f0d6deaf3d`.
All seven directory Git identities match, including root
`a13a450ad2445b98a18f93ec9f1907cae1b1784e`. The complete recursive tree,
archive path set, blob identities, sizes, digests, types and modes passed
persisted readback and an independent offline reconstruction.

This tree has three `160000` gitlinks. The retained `.gitmodules` supplies
their upstream URLs, but their source is not retained by this archive:

| Path | Pinned child revision |
| --- | --- |
| `third_party/benchmark` | `e991355c02b93fe17713efe04cbc2e278e00fdbd` |
| `third_party/glog` | `56523194b3ce1212414c93d55f31832e94677f55` |
| `third_party/googletest` | `3b49be074d5c1340eeb447e6a8e78427051e675a` |

Directory placeholders do not supply these child repositories. The receipt
`webrtc-crc32c-d3d60ac6-source.json` records complete repository-blob
retention and incomplete recursive source retention. It is 34,158 bytes,
SHA-256 `22cf6fee02588961e91d923eb9118e48e6c9b1034460f41c50288a3a06e95e98`.
The existing build-source reference binds both files and the unretained pins.
No upstream code was executed, and no complete dependency checkout or native
reproduction is claimed.

### Retained crc32c pinned child repositories

The three child sources listed above are now retained in separate private
archives at their exact gitlink revisions. The standalone parent archive and
its original receipt remain unchanged and nonrecursive.

| Child | Blobs / directory trees | Archive bytes | Archive SHA-256 |
| --- | --- | --- | --- |
| google/benchmark | 156 / 17 | 176,771 | `914f898c9efcd4d328dafad10df0cdc59708771acf66c29eaf0becc38a140a04` |
| google/glog | 97 / 14 | 188,448 | `92ac23e5f535beb70dfde7417904903c9a130adf194684f1497930f2060c2027` |
| google/googletest | 235 / 30 | 832,010 | `c93fee5b85a4c8e366cb754f58874c8979438ba0da5442c995a6024dd5b42c28` |

Each child has no further gitlinks. Complete commit/tree metadata was saved
before archive acquisition. Archive readback and a second independent offline
reconstruction verified every directory Git identity, the complete unique safe
blob and directory path sets, Git blobs, sizes, SHA-256, types and executable
semantics. Git modes and raw archive modes are recorded separately. No
upstream code was extracted or executed.

The existing build-source reference binds each child archive and receipt under
`implementationSourcePreparation.sources` → crc32c →
`gitlinkChildSourcePreparation`. Receipt SHA-256 values are:

- `webrtc-crc32c-benchmark-e991355c-source.json`: `97eb044d29d16aaf725a0bf222df273b751f6db19feb8d542d90b75d8a362cfa`.
- `webrtc-crc32c-glog-56523194-source.json`: `f4e5221c462f04404a0f86a0834fec0e2bb6fae97a62c9b2834d7f3ba9a82f74`.
- `webrtc-crc32c-googletest-3b49be07-source.json`: `50202ac7e5074f8f60a9db57f47f18f764d099fad9151b946a992969cb534a32`.

Pinned crc32c CMake defaults enable tests, benchmarks and glog, which select
these three child directories. The pinned Android builder instead delegates
AAR generation to `build_aar.py` and separate ABI builds to GN/autoninja.
The Chromium crc32c GN wrapper and original GN invocation are not retained,
so this inspection does not establish their actual dependency selection.

This completes source retention for the standalone crc32c parent and its exact
three children as separate archives. Remaining WebRTC DEPS/CIPD/tool inputs,
complete applied checkout, original GN/toolchain invocation, native reproduction,
final notices/rights, exact signed candidate, actual recipient retrieval/fresh
build and release acceptance remain open.

### Retained pinned compact_enc_det dependency source

Engine DEPS selects `src/third_party/ced/src` at
`ba412eaaacd3186085babcd901679a48863c7dd5` in Google's upstream
`google/compact_enc_det` repository. The private archive
`webrtc-compact-enc-det-ba412eaa-source.tar.gz` retains all 27 blobs:
301,917 bytes, SHA-256
`a2c967e40a4f9448e8af8e9c2594a9bc517fa9d491b70e22f1c97b35f26bacb2`.
All five directory identities match, including root
`6fbb4c383f8957ff9c1d9d01ad1e117f3b11fc93`. The complete recursive tree
has no gitlinks. Exact safe unique path sets, Git blobs, sizes, SHA-256,
types and executable semantics passed persisted readback and an independent
offline reconstruction. Git and raw archive modes are recorded separately.

The receipt `webrtc-compact-enc-det-ba412eaa-source.json` is 23,147 bytes,
SHA-256 `6fa6905c3fc61d06fd3132187220c4d18e1cd24598e3b10ff6a4f376223d1f5e`.
The existing build-source reference binds both files to the engine DEPS pin.
Complete applied checkout and remaining WebRTC DEPS/CIPD/tool inputs,
original GN/toolchain invocation, native reproduction, final notices/rights,
exact signed candidate, actual recipient retrieval/fresh build and release
acceptance remain open. No upstream code was executed. Existing evidence and
incomplete JNI-zero/buildtools caches are unchanged.

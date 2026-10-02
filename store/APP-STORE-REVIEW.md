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
used only after starting voice. Notification permission is optional. Face ID is
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

# Papercusp Android — Google Play data-safety answers

_Source draft reconciled October 2, 2026 against the Android manifest,
`VoicePrivacyConsent`, `PrivacyPolicyScreen`, `VoiceManager`,
`DesktopVoiceSession`, `PushService`, `Credentials`, and Gradle dependencies._

Use this draft worksheet for **Play Console → App content → Data safety**.
The answers below describe the intended release behavior. They are not evidence
that a signed candidate was tested, uploaded, or accepted by Google Play.
Re-run the verification checklist against the exact candidate before submitting
and retain the submitted Console answers with its APK/AAB hashes.

## Source reconciliation

| Declaration | Current source basis | Required candidate evidence |
|---|---|---|
| Cloud voice is optional | `VoicePrivacyConsent.kt` defaults consent to false, supports revocation, and names ElevenLabs, audio, transcripts, replies and provider processing. `VoicePrivacyConsentTest.kt` checks the consent boundary and disclosure. | Verify consent blocks capture in the signed app, revocation prompts again, and desktop-local voice follows its declared route. |
| Push and crash diagnostics remain included | `app/build.gradle.kts` includes Firebase Messaging and Crashlytics; `PrivacyPolicyScreen.kt` and the public policy disclose both. | Verify actual push delivery and crash behavior, including which identifiers and failure context leave the device. |
| Analytics and advertising identifiers are disabled | The source manifest disables Firebase Analytics, ad-ID and SSAID collection and removes inherited advertising, attribution and install-referrer permissions. `android-privacy-permissions-test.sh` checks the merged release manifest. | Inspect the exact APK/AAB merged manifest and retain the executed privacy-check result. |
| Configured Android wake-word builds continuously use the microphone | `MainActivity.kt` starts `WakeWordService` when a wake-word engine is configured and microphone permission is granted, including idle state. The service declares the microphone foreground-service type and displays an ongoing notification. | Record the candidate's effective wake-word configuration without exposing its key; test idle/background listening, notification, permission denial and teardown. Review Picovoice operational reporting, account terms and sharing declarations if activated. |
| Android release connections require HTTPS | Release configuration disables cleartext; the release pairing boundary rejects non-HTTPS endpoints. | Exercise rejected HTTP and accepted production HTTPS pairing on the exact signed candidate. |
| Public privacy and deletion contacts exist | The public privacy and support pages returned HTTP 200 with their privacy/deletion content during the October 1 review. The public policy includes the same shipped processors as the in-app policy. | Recheck both URLs immediately before submission and exercise the support/deletion process. |

Provider contracts, configured retention, the service-provider exception used
below, and the actual Play form still require submission-time review. Source
checks do not establish those external facts or replace the physical-phone and
exact-candidate acceptance matrix.

## Overview answers

- **Does the app collect or share required user data types?** Yes.
- **Is all user data encrypted in transit?** Yes for the public release. Release
  builds reject non-HTTPS pairing endpoints and set `usesCleartextTraffic=false`.
- **Can users request deletion?** Yes —
  <https://papercusp.com/mobile/support>. Users can also revoke cloud voice
  consent, forget the device, clear app data, or uninstall.
- **Data sold:** No.
- **Data used for advertising or cross-app tracking:** No.

## Data types

The **Shared** answers below are provisional. Google's service-provider
exception requires processing on the developer's behalf and instructions; an
SDK name or consent prompt alone does not establish that exception. Verify each
processor's applicable contract and actual account settings before entering
**No** in Play Console. If no exception is established, disclose the transfer
as shared. A qualifying user-initiated action or prominent disclosure and
consent is a separate exception and needs its own evidence from the candidate.

In particular, ElevenLabs documents model-improvement use with an account
opt-out for future submissions. The configured account's choice has not been
verified here. Cloud audio, transcripts and functional identifiers therefore
remain unresolved for sharing; the policy's disclosure of possible training
must not be treated as proof that all processing is solely on our behalf.

| Play data type | Collected | Shared | Required/optional | Purpose | Linked to identity | Tracking |
|---|---:|---:|---|---|---:|---:|
| Audio → Voice or sound recordings | Yes | Pending exception review | Optional (cloud voice only) | App functionality | Yes, to a functional device/user ID | No |
| Messages / Other user-generated content → cloud voice transcripts and replies | Yes | Pending exception review | Optional (cloud voice only) | App functionality | Yes, to a functional device/user ID | No |
| App info & performance → Crash logs | Yes | No only with verified processor exception | Automatic when a crash occurs | Diagnostics | No | No |
| App info & performance → Diagnostics (device model, OS, failure context) | Yes | No only with verified processor exception | Automatic when a crash occurs | Diagnostics | No | No |
| Device or other IDs → FCM token and Crashlytics installation ID | Yes | Review each destination's exception separately | FCM functional; Crashlytics automatic | App functionality, diagnostics | FCM token links to the paired device; Crashlytics ID is pseudonymous | No |

Chat and command content sent only to the user's paired operator is not collected
by the developer. If the paired operator sends that content to its configured AI
provider, that processing is controlled by the operator administrator. Firebase
Analytics, ad-ID collection, and Android-ID analytics collection are disabled.

## Submission-time verification

1. Inspect the merged **release** manifest: cleartext false; Firebase analytics,
   advertising ID, and SSAID collection false.
2. Install the signed release APK and prove an HTTP pairing payload is rejected
   while the production HTTPS endpoint is accepted.
3. Start desktop-local voice: no ElevenLabs consent prompt. Start cloud voice:
   the disclosure must block audio until **Agree and start** is tapped.
4. Revoke cloud voice in Settings and prove the next cloud session prompts again.
5. Confirm Crashlytics is intentional and receiving a release test crash, or
   remove Crashlytics and update this worksheet before submission.
6. Compare the Play Console form and privacy-policy URL with this file immediately
   before rollout; screenshots of the submitted answers belong in release evidence.
7. Retain the configured ElevenLabs account's data-use choice, per-agent audio
   saving and transcript/audio retention settings, applicable processor terms,
   and the reason for each sharing exception. Defaults in provider documentation
   are not evidence of this account's configuration. Verify support can locate
   and delete developer-controlled records without promising that uninstall or
   consent revocation deletes previously retained provider records.
8. Reconcile `RECORD_AUDIO`, `FOREGROUND_SERVICE` and
   `FOREGROUND_SERVICE_MICROPHONE` with the candidate's actual wake-word use and
   Play foreground-service declaration/demo. Microphone permission alone does
   not establish that the listener is configured. If Picovoice is activated,
   verify its reporting and applicable data types; the provisional table above
   does not settle those transfers. Verify the hosted privacy page includes the
   candidate's conditional wake-word disclosure before submission.

## Provider references checked October 1, 2026

- [Google Play Data Safety collection, sharing and exceptions](https://support.google.com/googleplay/android-developer/answer/10787469)
- [ElevenLabs model-improvement settings and prospective opt-out](https://elevenlabs.io/docs/help-center/legal/is-my-data-used-to-improve-eleven-labs-ai-models)
- [ElevenLabs conversation audio/transcript retention](https://elevenlabs.io/docs/eleven-agents/customization/privacy/retention)
- [ElevenLabs per-agent Zero Retention Mode](https://elevenlabs.io/docs/eleven-agents/customization/privacy/zrm)

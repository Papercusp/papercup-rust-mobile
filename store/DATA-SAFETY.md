# Papercusp Android — Google Play data-safety answers

_Source draft reconciled October 1, 2026 against the Android manifest,
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

Google's "shared" column is **No** below because Firebase, ElevenLabs, and their
subprocessors act as service providers for app functionality rather than using
the transfer for an independent third-party purpose. Re-evaluate if contracts or
provider use change.

| Play data type | Collected | Shared | Required/optional | Purpose | Linked to identity | Tracking |
|---|---:|---:|---|---|---:|---:|
| Audio → Voice or sound recordings | Yes | No | Optional (cloud voice only) | App functionality | Yes, to a functional device/user ID | No |
| Messages / Other user-generated content → cloud voice transcripts and replies | Yes | No | Optional (cloud voice only) | App functionality | Yes, to a functional device/user ID | No |
| App info & performance → Crash logs | Yes | No | Automatic when a crash occurs | Diagnostics | No | No |
| App info & performance → Diagnostics (device model, OS, failure context) | Yes | No | Automatic when a crash occurs | Diagnostics | No | No |
| Device or other IDs → FCM token and Crashlytics installation ID | Yes | No | FCM functional; Crashlytics automatic | App functionality, diagnostics | FCM token links to the paired device; Crashlytics ID is pseudonymous | No |

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

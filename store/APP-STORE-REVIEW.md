# App Store review and submission packet — iPhone 1.0

_Refreshed October 6, 2026 for bundle ID `com.papercuspai.operator.mobile`. This packet is preparation, not proof of submission or public availability._

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
- Distribution rights: the repository is licensed under GPL-3.0-or-later, and
  App Store terms may add restrictions that require separate permission.
  Papercusp holds all copyright in this repository and permits App Store
  distribution (owner ruling, October 6, 2026: plan
  iphone-public-release-2026-08-11, D-017). Re-check this before submission if
  any code from another copyright holder has been added.

## Pending: cloud workspace review notes (do not submit yet)

**Pending — not yet available.** The candidate cannot pair with a Papercusp
cloud workspace until the device relay (P-015) is verified live on it. Only
then move this text into the sections above.

- Review notes: "Papercusp is a companion to a Papercusp operator controlled by
  the app user, running on the user's desktop or in a Papercusp cloud
  workspace." Pairing: "…on a desktop or in a cloud workspace. A cloud
  workspace is reached through the Papercusp relay, so no local network is
  required; for a workspace in the customer's own cloud account, content is
  end-to-end encrypted between the phone and that workspace."
- Reviewer access: the preferred environment becomes a sanitized cloud
  workspace reached through the Papercusp relay, because it needs no local
  network and stays online throughout review.
- Checklist: cloud workspace pairing through the Papercusp relay is exercised on
  the exact candidate, against both a sanitized customer-cloud workspace
  (end-to-end encrypted, no plaintext content at the relay) and a
  Papercusp-hosted one.

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

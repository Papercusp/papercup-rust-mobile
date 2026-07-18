# Papercup — Privacy Policy

_App: **Papercup** (`com.papercuspai.operator.mobile`) · iOS + Android · v0.1.0_
_Draft prepared 2026-07-17 for App Store / Play Store submission (WI-5325). **Owner: review, then host at a public URL and paste that URL into App Store Connect + Play Console.**_

## The short version

Papercup is a **companion for your own Papercup desktop**. You pair the app to a
desktop you control ("your operator") and talk or chat with it. **Your voice and
messages are sent to your own operator — not to us.** We do not sell your data, we
do not show ads, and we do not run behavioral analytics on you.

## What the app handles, and where it goes

| Data | Why | Where it goes | Kept by us? |
|------|-----|---------------|-------------|
| **Voice audio** | Voice commands | Streamed to **your own operator** (your desktop) for speech-to-text, the assistant, and text-to-speech | **No** |
| **Chat text** | Chat with your operator | Sent to **your own operator** | **No** |
| **Pairing credential** (device token) | Authenticate the app to your operator | On your device + your operator | **No** |
| **Push token** (FCM / APNs) | Deliver notifications from your operator | Google FCM / Apple APNs + your operator | Only as a routing token |
| **Crash diagnostics** | Fix crashes | **Firebase Crashlytics** (Android). iOS crash reporting is currently disabled. | Yes, crash reports only |

We do **not** collect your name, email, contacts, calendar, location, photos, or
files. The app has no account and no sign-up — it authenticates to *your* desktop.

## Third-party services

- **Firebase Cloud Messaging** (Google) — delivers push notifications. Receives a
  device push token.
- **Firebase Crashlytics** (Google, Android only) — collects crash reports (stack
  trace, device model, OS version, a Crashlytics install identifier) **only when the
  app crashes**, so we can fix bugs.
- **Firebase Analytics is disabled** — behavioral analytics collection, advertising
  ID, and Android ID collection are turned off in the app manifest.
- **Sentry** (iOS crash reporting) is present but **inactive** in shipped builds (no
  DSN configured); if it is ever enabled, this policy and our store data-safety
  declarations will be updated to disclose crash-diagnostics collection on iOS.

We do not use any advertising SDKs and do not track you across apps or websites.

## Permissions

- **Microphone** — to hear your voice commands.
- **Camera** — to scan the pairing QR code shown by your desktop.
- **Notifications** — to deliver messages from your operator.
- **Face ID / biometric** (iOS) — to confirm high-risk actions like revoking a
  paired device. Handled by the OS; the biometric never leaves your device.

## Data retention & your control

- Voice/chat content is processed by **your own operator** under your control;
  retention there is governed by your desktop, not this app.
- Crash reports are retained by Firebase Crashlytics per Google's retention policy.
- **Unpair** the app (or revoke the device from your operator) at any time to sever
  the link; uninstalling removes the on-device pairing credential.

## Children

Papercup is not directed to children under 13.

## Changes & contact

We will update this policy as the app evolves. Questions: **[owner: add a support
email / URL]**.

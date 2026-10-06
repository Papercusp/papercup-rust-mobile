# Papercusp mobile privacy policy

_Source policy updated October 6, 2026; verify the hosted copy before submission_

This policy covers the Papercusp iPhone app and Android app with bundle/package
identifier `com.papercuspai.operator.mobile`. The public copy is available at
<https://papercusp.com/mobile/privacy>.

## Overview

Papercusp is a companion to a Papercusp operator you pair with: one running on
your own desktop, or a Papercusp cloud workspace that runs either in your own
cloud account or on infrastructure Papercusp operates for you. We do not sell
personal data, show ads, use behavioral advertising, or track people across
apps or websites. The mobile app does not require a Papercusp account.

## Data the apps handle

| Data | Use and destination |
|---|---|
| Pairing credential, device ID, workspace ID, and operator address | Stored on the phone and sent to the paired operator to authenticate the device. The iPhone credential is stored in the Apple Keychain; Android uses encrypted app storage. |
| Chat, commands, and operator replies | Sent to the paired operator. The operator may send prompts and replies to the AI provider configured by its administrator. |
| Cloud workspace connections | When the phone is paired with a cloud workspace, its connection travels through the Papercusp relay. For a workspace in your own cloud account, chat, voice, and other content are end-to-end encrypted between the phone and that workspace, so the relay cannot read them. The relay processes routing data such as the workspace ID, device ID, connection times, data sizes, and IP address to deliver the traffic and protect the service. For a workspace that Papercusp hosts, that content is processed and stored on Papercusp-operated infrastructure on behalf of the workspace owner and follows the workspace's settings. |
| Microphone audio and voice transcripts | Desktop-local voice sends data to the paired operator. Cloud voice is blocked until the user explicitly agrees; it sends audio, transcripts, replies, and functional identifiers to ElevenLabs and its service providers, including AI model providers. |
| Android wake-word microphone input, when configured | Picovoice Porcupine continuously uses microphone input to detect the activation word once microphone permission is granted, including while the app is in the background. A foreground-service notification indicates listening. Builds without wake-word configuration do not start this listener. This listener is separate from consented cloud voice. |
| Push token | Sent to Apple Push Notification service on iPhone, or Firebase Cloud Messaging on Android, and to the paired operator so notifications can reach the device. |
| Android crash logs, device/OS details, and Crashlytics installation ID | Sent to Firebase Crashlytics to diagnose Android failures. The iPhone 1.0 app does not include a crash-reporting SDK and does not send crash diagnostics to Papercusp. |

Cloud voice providers may record, view, store, and share communications to
provide and improve the service, train models when the applicable account has
not opted out, and comply with law. ElevenLabs documents a two-year default for
conversation audio and transcript retention unless the workspace is configured
for a shorter period or zero retention. Do not use cloud voice for information
you are not comfortable sending to those providers.

## Services and tracking

- **ElevenLabs Agents** powers the optional, consented cloud voice path. See
  [ElevenLabs retention controls](https://elevenlabs.io/docs/eleven-agents/customization/privacy/retention).
- **Papercusp relay** connects phones to cloud workspaces. For workspaces in a
  customer's own cloud account it carries only end-to-end encrypted content.
- **Apple Push Notification service** delivers iPhone notifications.
- **Firebase Cloud Messaging** delivers Android notifications.
- **Firebase Crashlytics** collects Android crash diagnostics.
- **Picovoice Porcupine**, on Android builds configured for wake-word listening,
  detects the activation word. Cloud-voice consent still applies separately.
- **Firebase Analytics is disabled.** Advertising-ID collection and Android-ID
  analytics collection are also disabled in the Android release manifest.
- **The iPhone 1.0 app has no crash-reporting SDK.** If crash reporting is
  enabled in a later version, the policy and App Store privacy answers must be
  updated before that build is submitted.

We do not include advertising SDKs and do not track users across apps or
websites.

## Permissions

- Microphone: voice interaction and, on configured Android builds, continuous
  wake-word listening with a foreground-service notification.
- Camera: scan a pairing QR code.
- Notifications: deliver messages from the paired operator.
- Local network on iPhone: connect directly to the paired desktop when it is on
  the same network.
- Face ID on supported iPhones: confirm high-risk actions such as revoking a
  paired device.

The apps do not request contacts, calendar, location, photos, or financial
information.

## Security, retention, and control

Public internet connections require HTTPS. Connections to a cloud workspace in
your own cloud account are also end-to-end encrypted between the phone and the
workspace, using a key the workspace shows during pairing. iPhone permits unencrypted traffic
only for Apple's local-network category so a phone can connect directly to a
paired desktop on the same trusted network. Android public release builds reject
non-HTTPS pairing endpoints and disable cleartext traffic.

On-device credentials and preferences remain until the user forgets the paired
device, clears app data, or uninstalls. Data on the paired operator follows that
operator's settings, including in a Papercusp-hosted cloud workspace. Relay
routing data is kept only as long as needed to operate and secure the service.
Cloud voice, notification, and Android crash data follow
the processors' configured retention and legal requirements.

Users can withdraw cloud voice consent in Settings; the next cloud session will
ask again. Users can also forget the paired device. To request deletion of
developer-controlled cloud voice or Android crash records, use
<https://papercusp.com/mobile/support>.

## Children, changes, and contact

Papercusp is not directed to children under 13. We will update this policy when
data practices materially change and present a new cloud-voice consent prompt
when required.

Questions or deletion requests: <https://papercusp.com/mobile/support> or
`access@papercusp.com`.

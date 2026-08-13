# App Store privacy answers — iPhone 1.0

_Source-reconciled August 11, 2026 against the iPhone source, dependencies,
privacy manifest, and public privacy policy._

Use this as the exact App Store Connect worksheet for bundle ID
`com.papercuspai.operator.mobile`. Re-check it against the exported archive
before submission.

## Overview answers

- **Does this app collect data?** Yes.
- **Is any data used to track users?** No.
- **Is data linked to the user's identity?** Yes, to the paired device/workspace
  identity used to provide operator and voice functionality.
- **Privacy policy URL:** <https://papercusp.com/mobile/privacy>
- **User privacy choices URL:** <https://papercusp.com/mobile/support>

Apple treats data sent off the device and retained beyond the immediate request
as collected. Optional cloud voice can be retained by ElevenLabs, and the
operator retains a functional device identity and APNs token, so the answer is
Yes even though Papercusp has no consumer account or advertising profile.

## Data types to declare

| App Store data type | Collected | Linked | Tracking | Purpose | Required |
|---|---:|---:|---:|---|---|
| User Content → Audio Data | Yes | Yes | No | App Functionality | Optional; cloud voice only |
| User Content → Other User Content | Yes | Yes | No | App Functionality | Optional; cloud voice transcripts and replies |
| Identifiers → Device ID | Yes | Yes | No | App Functionality | Required after pairing; includes functional device ID and APNs token |

## Data types not collected by the iPhone 1.0 app

- Contact Info, Health & Fitness, Financial Info, Location, Contacts, Browsing
  History, Search History, Purchases, Usage Data, Sensitive Info, and Other Data.
- Crash Data and Performance Data. The iPhone 1.0 target does not link or
  initialize a crash-reporting SDK.
- Typed chat and command content is sent to the user's paired operator rather
  than collected by Papercusp. An operator administrator may separately direct
  that content to its configured AI provider.

## Submission-time verification

1. Generate the privacy report from the exact exported archive and confirm that
   it includes the app privacy manifest plus dependency manifests.
2. Confirm the archive contains no Sentry framework, DSN, or crash reporter.
3. Start desktop-local voice and prove no ElevenLabs conversation starts.
4. Start cloud voice and prove the disclosure blocks transmission until the
   user taps **Allow cloud voice**.
5. Revoke cloud voice in Settings and prove the next cloud session prompts again.
6. Compare the App Store Connect form, this worksheet, and the live policy URL
   immediately before submission.

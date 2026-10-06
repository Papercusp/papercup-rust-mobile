# App Store privacy answers — iPhone 1.0

_Source-reconciled August 11, 2026 against the iPhone source, dependencies,
privacy manifest, and public privacy policy. Cloud workspace answers drafted
October 6, 2026 are pending in the last section; apply them only after the
device relay (P-015) is verified live on the exact candidate._

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

## Pending: cloud workspace answers (do not enter yet)

**Pending — not yet available.** The candidate cannot pair with a Papercusp
cloud workspace until the device relay (P-015) is verified live. Only then
replace the matching answers above with these, re-reconcile them against the
relay build, and publish the pending section of `store/PRIVACY-POLICY.md`.

- Overview addition: "A Papercusp-hosted cloud workspace stores the user's
  chat, commands, and voice on Papercusp-operated infrastructure, so that
  content is collected too. A workspace in the customer's own cloud account
  receives content end-to-end encrypted through the Papercusp relay, which
  processes only routing data."
- Audio Data → Required: "Optional; cloud voice, or voice sent to a
  Papercusp-hosted cloud workspace".
- Other User Content → Required: "Cloud voice transcripts and replies; chat and
  commands sent to a Papercusp-hosted cloud workspace".
- Device ID → Required: "Required after pairing; includes functional device ID,
  APNs token, and relay routing for cloud workspaces".
- Not-collected bullet: "Typed chat and command content sent to a paired
  desktop, or end-to-end encrypted to a workspace in the customer's own cloud
  account, is not collected by Papercusp. Content sent to a Papercusp-hosted
  cloud workspace is collected as declared above. An operator administrator may
  separately direct that content to its configured AI provider."
- Added verification step, before the final comparison: "Pair with a sanitized
  workspace in a customer's own cloud account through the Papercusp relay, and
  prove the relay records no plaintext chat, voice, or command content for it.
  Pair with a sanitized Papercusp-hosted workspace and confirm its content
  handling matches the declarations above."

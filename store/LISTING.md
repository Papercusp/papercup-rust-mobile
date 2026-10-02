# Papercusp mobile store listing

_Release copy · refreshed October 1, 2026; candidate assets and Apple availability require final verification_

- **App name:** Papercusp
- **Subtitle (iOS):** Your operator, wherever you are
- **Short description (Android):** Voice and chat companion for your own Papercusp desktop operator.
- **Category:** Productivity
- **Support URL:** <https://papercusp.com/mobile/support>
- **Marketing URL:** <https://papercusp.com/>
- **Privacy policy URL:** <https://papercusp.com/mobile/privacy>
- **iOS bundle ID:** `com.papercuspai.operator.mobile`
- **Android package:** `com.papercuspai.operator.mobile`

## Promotional text

Pair with the Papercusp operator you control, then keep up with its work and
respond from your phone.

## Full description

Papercusp turns your iPhone or Android phone into a voice and chat companion
for the Papercusp desktop operator you control.

In desktop Settings → Remote access → Pair a phone, scan the code or paste the pairing payload. Then:

- Talk or type to your operator from anywhere.
- See plans, current fleets and pots, agent availability, notifications, and recent work.
- See system-health alerts alongside the work that needs your attention.
- Approve sensitive actions and manage paired devices.
- Use desktop-local voice, or explicitly opt in before cloud voice sends audio
  and transcripts to ElevenLabs and its service providers.
- Receive notifications when the operator needs attention.

Papercusp has no ads and does not use behavioral analytics or sell personal
data. Public internet connections use encrypted HTTPS. Local-network access is
limited to connecting directly to a paired desktop. A paired Papercusp desktop
is required for live operator features.

## Keywords (iOS)

AI assistant,operator,productivity,voice,automation,desktop,companion,workflow

## Version 1.0 release notes (iOS)

The first public iPhone release includes secure QR pairing, operator chat,
voice, plans, fleet status, notifications, standing approvals, diagnostics,
and explicit cloud-voice privacy controls.

## Version 0.1.0 release notes (Android)

The first public Android release includes secure QR pairing, operator chat,
voice, plans, fleet status, notifications, standing approvals, diagnostics,
and explicit cloud-voice privacy controls.

## Required assets

- App icon: bundled in the platform asset catalogs.
- iPhone screenshots: pair, inbox, operator chat, plans, fleet, settings,
  privacy policy, and cloud-voice consent from the release candidate. Include a
  sanitized system-alert-only Inbox and the current fleet/pot availability view.
- Android phone screenshots: the same product flow from the release candidate.
- Google Play feature graphic: `store/feature-graphic.png`, 1024 × 500,
  rendered from `docs/wordmark-source/feature-graphic.svg` and the existing canonical
  `docs/wordmark-source/wordmark.svg`. This brand asset contains no candidate
  screenshots, rating claims, store badges, or availability claims.

Re-render the feature graphic from the repository root with the same
`rsvg-convert` renderer used for the app's existing wordmark assets:

```sh
rsvg-convert -w 1024 -h 500 docs/wordmark-source/feature-graphic.svg -o store/feature-graphic.png
```

Keep the official wordmark and the DejaVu Sans font available during rendering;
inspect the exported PNG before upload. The graphic is prepared locally and
does not establish that a candidate or store listing has shipped. Final Android
screenshots still come from the exact accepted signed candidate after P-009.

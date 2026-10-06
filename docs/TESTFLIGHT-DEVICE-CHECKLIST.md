<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# TestFlight device checklist (iPhone 1.0)

These are the acceptance rows that only a real iPhone can close
(iphone-public-release-2026-08-11: P-008 R-2 onboarding and access, P-005
delivery, D-017 "device checks via TestFlight"). CI already covers the
simulator half: the pairing UI smoke, revoked-token re-pair and fresh-install
reset run on every iOS gate.

Record each row as pass or fail, with the TestFlight build number and the time.
For a failure, include a screenshot or screen recording. Use Settings → Screen
Recording, and keep tokens and pairing codes out of the frame.

## Before you start

- The build: run `gh workflow run testflight.yml -R Papercusp/papercup-rust-mobile`
  (see `docs/BUILD.md` → TestFlight). Wait until App Store Connect finishes
  processing the build, then install it from the TestFlight app.
- The phone: delete any earlier Papercusp build first, so this is a clean install.
- The desktop: a running Papercusp desktop on the same Wi-Fi. For push rows, the
  operator also needs the APNs key configured (`APNS_KEY_PATH`, `APNS_KEY_ID`,
  `APNS_TEAM_ID`).

## Rows

| # | Do this | Pass when |
|---|---|---|
| 1 | Open the app for the first time | The pair choices appear and nothing is pre-filled from an earlier install |
| 2 | Pair with the desktop over Wi-Fi from its Remote access screen | The workspace loads and a chat reply streams in |
| 3 | Turn Wi-Fi off and use cellular, then send a message | The reply still arrives over HTTPS (tunnel or relay), with no LAN address in use |
| 4 | Quit the desktop app while on cellular | The phone shows the desktop as offline (not "unpaired"), then reconnects by itself when the desktop is back |
| 5 | Revoke this phone on the desktop | The phone asks to pair again; it does not report the desktop as offline |
| 6 | Delete and reinstall the app from TestFlight | The old pairing is gone and the pair choices appear again |
| 7 | Lock the phone, then make the desktop raise something that notifies (for example an agent question) | A push notification arrives, and tapping it opens the right conversation |
| 8 | Accept, then on another run deny, the notification, microphone and camera prompts | Each prompt explains why it is asked; a denial leaves the rest of the app usable |
| 9 | Start voice for the first time | A cloud-voice consent prompt comes before any audio leaves the phone |
| 10 | Pair with a BYOC cloud workspace | **Pending P-015** (cloud relay transport). Skip until the release notes say cloud pairing is in the build |

When every row except 10 passes on one build, that build is the device
evidence for P-008 R-2. Row 10 is the device check for D-014 (cloud
compatibility) once P-015 ships.

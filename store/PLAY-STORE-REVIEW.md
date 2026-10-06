# Google Play review and submission packet — Android

_Split from `store/APP-STORE-REVIEW.md` on October 6, 2026 for package
`com.papercuspai.operator.mobile`. This packet is preparation, not proof of
submission or public availability._

This file is the Android counterpart of the Apple packet in
`store/APP-STORE-REVIEW.md`. It holds only what a Play reviewer, or the person
submitting to Play Console, needs: review notes, reviewer access, the
submission checklist and operator commands. Build, license and source-provenance
evidence belongs in `android/SOURCE-EVIDENCE.md`, never here;
`tools/tests/store-packet-scope-test.sh` enforces that boundary.

## Reviewer preparation

Use the shared pairing and privacy copy in `store/LISTING.md` and
`store/PRIVACY-POLICY.md` (drafted by the iPhone lane under
`iphone-public-release-2026-08-11#D-016`, reviewed for Android under
`android-public-release-2026-10-01#D-012`), with these Android requirements. This section is a draft; reviewer access has
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
- Cloud workspace pairing is **pending** on Android (P-015). Until the exact
  candidate pairs from a cloud workspace's Settings → Remote access over the
  sealed relay (D-013: Noise XX end-to-end, relay sees only ciphertext), base
  reviewer access on a paired desktop or its own HTTPS tunnel. Do not mention
  cloud workspaces in review notes or screenshots. Once P-015 is verified live,
  add the cloud path to the notes and the pending cloud rows to Data safety.
- Use the final `store/DATA-SAFETY.md` answers only after the provider-account
  and exact-candidate checks pass. Include Firebase Messaging/Crashlytics,
  optional ElevenLabs processing, the merged permissions, and publicly
  reachable privacy/support/deletion guidance.
- Record whether the exact Android build configures wake-word listening. When
  enabled, verify idle/background microphone capture, the foreground-service
  notification, permission-denied behavior and teardown. A dormant keyless build
  does not prove configured behavior. Reconcile the microphone foreground-service
  declaration and its demonstration with the actual candidate; do not describe
  its microphone as active only after tapping voice. Before submitting, verify
  the hosted policy includes the candidate's wake-word disclosure; the October 2
  source-policy update alone does not prove the public page was updated.
- Capture the candidate's Android phone screenshots and 1024 × 500 feature
  graphic specified in `store/LISTING.md`. Document distribution rights and
  required third-party notices; record the corresponding source location and
  license obligations for the shipped GPL-3.0-or-later build.

Candidate bytes, reviewer access, provider settings, final disclosures, assets
and licensing evidence remain acceptance requirements. A launcher smoke test
does not verify this reviewer journey or the physical-phone/Play-install matrix.

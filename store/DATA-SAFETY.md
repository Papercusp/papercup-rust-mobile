# Papercup — Store data-safety declarations

_Draft 2026-07-17 (WI-5325). Fill these into **Play Console → App content → Data safety**
and **App Store Connect → App Privacy**. Grounded in the app's actual data flows +
linked SDKs. **Assumes the WI-5325 manifest fix is shipped** (Firebase Analytics
collection disabled — commit `bd258ec`); re-verify at ship time (see "Verify" below)._

## Core stance

Papercup is a companion to the user's **own** desktop operator. Voice/chat **content**
is sent to that operator (the user's machine), **not** to the developer — so it is
**"data processed but not collected by the developer"**, not developer data collection.
No behavioral analytics, no ads, no cross-app/website tracking, no data sale.

---

## Google Play — Data safety form

**Does your app collect or share any of the required user data types?**
→ **Yes** (diagnostics + a functional device identifier below). *Data is not sold or
shared with third parties for their own use.*

| Data type | Collected | Shared | Purpose | Linked to identity | Used for tracking |
|-----------|-----------|--------|---------|--------------------|-------------------|
| **Crash logs** (App info & performance → Crash logs) | Yes | No | App functionality / diagnostics | No | No |
| **Diagnostics** (device model, OS version) | Yes | No | Diagnostics | No | No |
| **Device or other IDs** (FCM push token; Crashlytics install ID) | Yes | No | App functionality (push), diagnostics | No | No |
| Audio / voice recordings | **No** (streamed to the user's own operator; not collected by us, not stored by us) | No | — | — | — |
| Messages / other content | **No** (sent to the user's own operator) | No | — | — | — |
| Personal info (name, email), Contacts, Location, Photos, Calendar, Financial | **No** | No | — | — | — |
| App activity / analytics | **No** (Firebase Analytics collection disabled) | No | — | — | — |

- **Data is encrypted in transit:** Yes.
- **Users can request deletion:** Crash data — via developer request; on-device
  pairing data is removed by unpairing/uninstall.
- **Committed to Play Families policy / independent security review:** N/A (owner to confirm).

## Apple App Store — App Privacy ("nutrition label")

- **Data Used to Track You:** **None.**
- **Data Linked to You:** **None.**
- **Data Not Linked to You:**
  - **Diagnostics → Crash Data** — *only if iOS crash reporting (Sentry) is enabled.*
    **Currently DISABLED** (no `SENTRY_DSN` in shipped iOS builds) → declare **"Data
    Not Collected"** for iOS as shipped today. If Sentry is enabled later, add
    *Diagnostics → Crash Data (not linked, not for tracking)* here AND update
    `ios/Papercup/Resources/PrivacyInfo.xcprivacy` (currently declares no collected
    data types — accurate only while Sentry is off).
  - **Identifiers → Device ID** — APNs push token (functional), if push is declared.

> Note the platform asymmetry: **Android** collects crash diagnostics (Crashlytics)
> + FCM token; **iOS** currently collects nothing third-party (Sentry off, no
> Firebase). Both declarations above reflect that truthfully. To make them symmetric,
> either enable Sentry on iOS (then declare iOS crash data) or disable Crashlytics on
> Android (then Android declares only the FCM token) — **owner decision.**

---

## Verify at ship time (do not skip)

1. **Android — Analytics actually off:** build the release AAB, run on emulator/device,
   confirm **no** `_e` analytics events in Firebase DebugView / `adb logcat -s FA FA-SVC`.
   Manifest flags: `firebase_analytics_collection_enabled=false`,
   `google_analytics_adid_collection_enabled=false`,
   `google_analytics_ssaid_collection_enabled=false` (commit `bd258ec`).
2. **Crashlytics on:** force a test crash, confirm it lands in the Firebase console
   (or disable Crashlytics too if the owner prefers zero collection).
3. **iOS — Sentry off:** confirm no `SENTRY_DSN` in the archived build's `Info.plist`.
4. Re-read this file against the shipped build before submitting either form.

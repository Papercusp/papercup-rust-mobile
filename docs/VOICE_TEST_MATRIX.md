<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Voice V1 — manual test matrix

**Purpose**: pass/fail checklist for an end-to-end voice run before any V1 ship-readiness call. Mirrors `VOICE_V1_PLAN.md` §Test plan with concrete steps the operator can execute without re-reading the design.

**Prerequisites** before any row runs:
- Operator desktop launched (embedded-pg up, dev server :3055 reachable)
- ElevenLabs account has remaining concurrent-session capacity and monthly characters
- Device paired (heartbeat 200 in `/tmp/operator-dev.log`)
- APK + iOS .app built from `master` HEAD

---

## A. Sanity (5 min, all envs)

| # | Step | Expected | Pass |
|---|------|----------|------|
| A1 | Tap Listen on idle screen | FAB → "Connecting" → "Listening" within 2s. Greeting plays. | ☐ |
| A2 | Say "what time is it" | Agent speaks current time within 5s. | ☐ |
| A3 | Stay silent for 2 min | Banner: `Voice idle 2m — tap to resume.` Session ends cleanly. | ☐ |
| A4 | Tap "Resume" on banner | FAB cycles back through Connecting/Listening. | ☐ |
| A5 | Tap Listen → background app immediately | Logcat: `lifecycle ON_STOP — ending active voice session`. No EL minute burn beyond ~3s. | ☐ |

If any A row fails, **stop**. Don't proceed to the rest until the basics are healthy.

---

## B. Failure-mode UX matrix (15 min)

Each row triggers a specific failure path and checks that the banner UX is correct.

| # | Trigger | Expected banner + action | Pass |
|---|---------|--------------------------|------|
| B1 | Revoke RECORD_AUDIO from Settings → Apps → Papercup → Permissions → Microphone, then tap Listen | "Mic permission denied." + "Settings" button → opens app-info screen | ☐ |
| B2 | Stop desktop binary, then tap Listen | "Voice unavailable — operator desktop is offline. Launch Papercup on your computer, then tap retry." | ☐ |
| B3 | Tap Listen rapidly 5× within 8s | Cooldown countdown banner: "Cooling down — retry in Ns." Counter decrements 1/sec. Manual cancel works. | ☐ |
| B4 | Have a second device hold voice lease, then tap Listen on this one | "Another device has voice. Pre-empt?" → tap pre-empts, second device demotes within 2s | ☐ |
| B5 | Enable airplane mode mid-session | "Lost connection — tap to retry." | ☐ |
| B6 | Hit idle timeout (2m silent) | "Voice idle 2m — tap to resume." → Resume button works | ☐ |
| B7 | Hit session-max (30m active) | "Voice session hit 30m max — tap to start another." | ☐ |
| B8 | Ask a definitive question in **Hybrid** mode ("mark sheets as paused") | Agent ends session, banner: "Conversation ended — tap to start another." auto-dismisses in 2s | ☐ |

Each banner must be **distinguishable at a glance** — wrong banner is a P0 bug (worse than no banner because user takes the wrong recovery step).

---

## C. Tool-parity verification (10 min)

Pick one tool from each `browser:` class. Both desktop and mobile must produce the same end state.

| # | Voice query | Tool fired | Class | Phone behavior | Pass |
|---|-------------|------------|-------|-----------------|------|
| C1 | "show me sheets" | `nav_open_harness` | required | Phone navigates to Detail screen | ☐ |
| C2 | "pause" | `operator_pause` | optional | Both desktop + phone show paused banner within 8s | ☐ |
| C3 | "what's running?" | `harness_list` (via proxy) | none | Agent speaks harness list from PG — phone doesn't try to render anything | ☐ |
| C4 | "marketplace" | `navigate` with `/marketplace` | required | Agent says "Marketplace isn't available on the phone yet" — no nav | ☐ |

---

## D. Source-agnostic verification (15 min)

Run identical queries against desktop, then phone. Audit log column `surface` must distinguish.

| # | Query | Desktop surface | Phone surface | Pass |
|---|-------|-----------------|---------------|------|
| D1 | "what harnesses are running" | browser | mobile-android | ☐ |
| D2 | "pause operator" | browser | mobile-android | ☐ |
| D3 | (iOS) "show me sheets" | n/a | mobile-ios | ☐ |

Verify in PG:
```sql
SELECT created_at, surface, command_id, principal
FROM harness_shared.command_audit
ORDER BY created_at DESC LIMIT 20;
```

`surface` should reflect the source. **Same agent prompt + same tool registry across both → bit-identical execution.**

---

## E. Lease handoff (10 min, requires desktop + phone)

| # | Step | Expected | Pass |
|---|------|----------|------|
| E1 | Start voice on desktop → tap Listen on phone | Desktop demotes within 2s (voice tab dims or shows "another device") | ☐ |
| E2 | Phone in voice → press power button (lock screen) → wait 12s | Desktop auto-reclaims; phone session ends | ☐ |
| E3 | Cellular phone in voice → desktop on different network → both try simultaneously | Whichever minted later wins; loser gets ConcurrentLimit banner | ☐ |

---

## F. Continuous turn-taking & barge-in (10 min)

| # | Step | Expected | Pass |
|---|------|----------|------|
| F1 | 5-turn conversation, never re-tap | Each turn answered within 5s, idle never fires while either is speaking | ☐ |
| F2 | Mid-TTS: user starts speaking | Agent stops TTS within 500ms, captures new utterance, continues | ☐ |
| F3 | User issues a follow-up referring to prior turn ("show me the second one") | Agent uses prior context — proves memory is shared | ☐ |

---

## G. Wake-word (dry-run today, hot-run when Picovoice key arrives)

### Dry-run (key empty)

| # | Step | Expected | Pass |
|---|------|----------|------|
| G1 | Fresh install, no key in `local.properties` | App launches, no FGS-microphone notification, no crash | ☐ |
| G2 | Logcat tag `WakeWord` | `isConfigured() = false` (no engine selected) | ☐ |

### Hot-run (Picovoice key in `local.properties:PICOVOICE_ACCESS_KEY=...`, then rebuild)

| # | Step | Expected | Pass |
|---|------|----------|------|
| G3 | Launch app | FGS-microphone notification "Wake word listening" visible | ☐ |
| G4 | Say "hey papercup" with screen off | Voice FAB transitions to Listening; full conversation works | ☐ |
| G5 | Tap voice FAB manually during wake-word listening | WakeWordService pauses; no mic contention | ☐ |
| G6 | End voice session | WakeWordService resumes listening for next "hey papercup" | ☐ |

### openWakeWord variant (flag flip)

| # | Step | Expected | Pass |
|---|------|----------|------|
| G7 | Set `PAPERCUP_USE_OWW=true` in `gradle.properties`, rebuild without Picovoice key | App launches with OWW model bundled, wake detection works on-device | ☐ |

---

## H. Performance HUD smoke (5 min)

Voice Settings → Performance section. After running a handful of sessions:

| Metric | Expected range | Pass |
|--------|----------------|------|
| First-word latency P50 | < 1500ms | ☐ |
| First-word latency P95 | < 3000ms | ☐ |
| Session length P50 | matches actual usage | ☐ |
| Total sessions | increments per tap | ☐ |

If P95 > 5s, file a backend perf bug. If counter doesn't increment, the HUD wire is broken.

---

## I. Cellular vs Wi-Fi (10 min)

| # | Network | Expected | Pass |
|---|---------|----------|------|
| I1 | Wi-Fi → tap Listen → 3-turn | All turns < 2s response time | ☐ |
| I2 | Cellular (LTE/5G) → same | Acceptable degradation: ≤ 50% slower than Wi-Fi | ☐ |
| I3 | Wi-Fi → start voice → kill Wi-Fi mid-session, cellular takes over | Session continues OR fails gracefully with NetworkUnreachable banner | ☐ |

---

## J. iOS-only checks

| # | Step | Expected | Pass |
|---|------|----------|------|
| J1 | App in active scene, tap Listen | Full path works (same as Android A1) | ☐ |
| J2 | Background app | scenePhase=.background ends voice session | ☐ |
| J3 | Lock screen via power button | Session ends within 2s | ☐ |
| J4 | Return to foreground, no auto-restart | FAB shows Idle, ready to re-tap | ☐ |
| J5 | App-version banner displays correct EL SDK version | (visual confirmation in About) | ☐ |

---

## How to run this matrix

1. Print this doc or open it on a separate screen.
2. Tick each row as you go.
3. For any **fail**, capture:
   - Logcat or Xcode console snippet
   - Screenshot of the wrong UI state
   - Exact reproduction steps
4. File against `papercup-rust-mobile` with the row number (e.g., `B2 fail: shows generic "unavailable" instead of desktop-offline copy`).
5. **No row may be skipped** for the V1 ship readiness call. Skip-tracking corrupts the signal.

---

## Coverage notes

This matrix does **not** cover:
- Long-running stability (>30 min single session) — caught by session-max ceiling
- Multi-workspace voice — V2; today voice is workspace-scoped to current pair
- Apple Developer Program-gated checks (TestFlight, real-iPhone-on-cellular) — requires $99/year account
- Mesh / Defguard handoff during voice — V2

When those caps lift, append rows under the relevant section rather than starting a separate doc.

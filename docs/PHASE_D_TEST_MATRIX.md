# Phase D — Real-device test matrix

Manual checklist for validating mobile voice end-to-end on the
Fold5 (Android) and iPhone sim. Run through each row, mark
**✓** / **✗** / **N/A**, paste failures in a coord/mobile.jsonl
entry.

Sections are ordered shallow → deep. If a row in **0 — bootstrap** fails,
later rows likely will too — fix bootstrap first.

---

## 0 — Bootstrap

| # | Step | Pass criteria | Notes |
|---|---|---|---|
| 0.1 | Open app cold | Pairing screen renders with the wordmark logo (paper cup) | Tests new design |
| 0.2 | Pair via QR/payload | Lands on Operator tab, no error banner | Token from `mint-pair-token` |
| 0.3 | Heartbeat | `POST /api/mobile/heartbeat` shows 200 in dev.log every 30s | |
| 0.4 | Settings → Voice | Conversation mode + Timers + Wake word + Speech rate + Pitch + Voice + Test/Reset sections all visible | |

---

## 1 — Voice modes (one device at a time)

For each of the three modes, switch in Settings → Voice → Conversation mode, then run all 4 rows. Note expected behavior per mode.

### 1.A Continuous (default, ChatGPT-like)

| # | Step | Expected |
|---|---|---|
| 1.A.1 | Tap voice FAB | FAB → Listening (within ~2s) |
| 1.A.2 | Ask "what's the status of my sheets harness?" | Agent speaks a real summary; session stays open |
| 1.A.3 | Ask follow-up "what were the last 3 features?" | Same session, agent answers |
| 1.A.4 | Stop speaking for 2 minutes | Auto-disconnect with banner `Voice idle 2m — tap to resume.` |

### 1.B Hybrid

| # | Step | Expected |
|---|---|---|
| 1.B.1 | Tap FAB; say "pause the operator" | Agent acknowledges + calls `operator_pause`; agent calls `end_conversation` → session ends within ~1s of confirmation |
| 1.B.2 | Tap FAB; say "what's the time?" | Agent answers; calls `end_conversation` after |
| 1.B.3 | Tap FAB; ask a multi-step question that needs clarification | Agent asks for clarification; session stays open until you answer + it confirms |

### 1.C Single-utterance

| # | Step | Expected |
|---|---|---|
| 1.C.1 | Tap FAB; ask anything | Agent gives single response; session ends regardless of question type |
| 1.C.2 | Tap FAB; ask an ambiguous question | Agent picks most-likely interpretation, answers, ends |
| 1.C.3 | Confirm idle timer floor | Settings → Voice → idle minutes is ignored if mode is single-utterance |

---

## 2 — Failure modes

Each row should surface the **specific banner** (not a generic "voice unavailable").

| # | Trigger | Expected banner / action |
|---|---|---|
| 2.1 | Revoke mic permission then tap FAB | "Mic permission denied." + [Settings] button → opens system Settings → Papercup |
| 2.2 | Hammer FAB rapidly (3 taps within 8s) | "Cooling down — retry in Xs." countdown, no error |
| 2.3 | Open EL session on desktop, then tap FAB on phone | "Another device has voice. Pre-empt?" + [Pre-empt] button → ends desktop, starts phone |
| 2.4 | Toggle airplane mode while connected | "Voice error — tap to retry." (network kind) within ~5s |
| 2.5 | Let agent finish a definitive answer in hybrid mode | "Agent ended the conversation." auto-dismisses after 2s |
| 2.6 | Burn through EL minute cap (unlikely without setup) | "ElevenLabs limit hit" — verify via Voice Settings spend card |

---

## 3 — Network conditions

Run **continuous mode**, single test query, on each network.

| # | Network | Expected |
|---|---|---|
| 3.1 | Wi-Fi 5GHz, same subnet as desktop | First-word latency P50 < 2s |
| 3.2 | Wi-Fi 2.4GHz | First-word latency P50 < 3s |
| 3.3 | Cellular (4G/LTE) | First-word latency P50 < 4s |
| 3.4 | Cellular (5G) | First-word latency P50 < 3s |
| 3.5 | Cellular with weak signal (1-2 bars) | Either graceful "network error" banner OR connects with audio glitches (no crash) |
| 3.6 | Switch Wi-Fi → cellular mid-session | Either re-connect cleanly OR show retry banner |

Numbers come from the Performance HUD (Settings → Voice → Performance).

---

## 4 — Edge cases

| # | Step | Expected |
|---|---|---|
| 4.1 | Background app mid-session, return in 5s | Session resumes or banner offers Resume |
| 4.2 | Lock screen mid-session | Session continues (audio playback OK), unlock returns to listening |
| 4.3 | Phone call interruption | Voice session yields to call; banner on return |
| 4.4 | Bluetooth headset connect/disconnect | Audio routing follows; no crash |
| 4.5 | Rapid mode-switch (Continuous → Hybrid → Single) without restarting voice | Switch takes effect on **next** session start; no stale state |
| 4.6 | Unpair while voice active | Session torn down, return to pair screen, no error toast |
| 4.7 | Pair on second device, both try to start voice | Lease handoff — second device gets "Another device has voice" banner |

---

## 5 — Tool surface

Each tool the EL agent can call. Test by asking a question that should trigger it. Note in **what?** column whether it actually fired (check dev.log for `/api/mobile/voice-tool/<name>` POSTs).

| # | Tool | Sample query | Hit? |
|---|---|---|---|
| 5.1 | `harness_list` | "what harnesses do I have?" | |
| 5.2 | `harness_status` | "status of sheets" | |
| 5.3 | `harness_list_features` | "what features did sheets pass yesterday?" | |
| 5.4 | `harness_last_scan` | "what was operator's last scan say?" | |
| 5.5 | `harness_recent_suggestions` | "what should I look at?" | |
| 5.6 | `harness_health` | "is sheets healthy?" | |
| 5.7 | `actions_recent` | "what did I just do?" | |
| 5.8 | `notifications_recent` | "any notifications?" | |
| 5.9 | `panel_state` / `panel_cards` | "what's on my panel?" | |
| 5.10 | `panel_dispatch_card` | "approve card X" | |
| 5.11 | `workspace_list` | "what workspaces?" | |
| 5.12 | `workspace_switch` | "switch to the storewolf workspace" | |
| 5.13 | `voice_prefs` | "what's my voice setup?" | |
| 5.14 | `operator_pause` (native) | "pause" | Native — no `/voice-tool/` hit |
| 5.15 | `operator_resume` (native) | "resume" | Native |
| 5.16 | `navigate` (native) | "go to the harnesses tab" | Native |
| 5.17 | `nav.openHarness` (native) | "show me sheets" | Native — tab nav |
| 5.18 | `ask_operator` (server-routed) | "explain what just happened" | Goes through operator-converse SSE |
| 5.19 | `end_conversation` (hybrid mode) | any definitive query | Agent calls; session ends |

---

## How to report results

1. After running, paste a summary into `coord/mobile.jsonl`:
   ```json
   {"ts":"<ISO-8601>","agent":"mobile","kind":"test-result","head":"<git-SHA>","platform":"android-fold5|ios-sim","summary":{"pass":N,"fail":N,"failures":["1.A.4 idle timer didn't fire"]}}
   ```
2. For any failure, attach the relevant dev.log slice and logcat (Android) / Console.app (iOS) capture.
3. If reproducible on real device but not emulator/sim, note the cellular state.

---

## Quick reference

### Mint a fresh pair token (loopback only)
```bash
curl -X POST 'http://127.0.0.1:3055/api/mobile/desktop/mint-pair-token' \
  -H 'content-type: application/json' \
  --data '{"workspaceId":"default"}' | jq .qrPayload
```

### Watch voice events in dev.log
```bash
tail -f /tmp/dev.log | grep -E 'voice-tool|voice-session|operator-converse|deviceAuth.*401'
```

### Force a specific failure kind for UX verification
- **MicPermission**: `Settings → Apps → Papercup → Permissions → Microphone → Deny`, then tap FAB
- **MintCooldown**: tap FAB, wait 3s, force-stop, retap. Inside the 8s cooldown the banner shows.
- **AgentEnded**: set Conversation mode → Hybrid, then ask a definitive question.

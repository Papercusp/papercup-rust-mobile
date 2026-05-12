<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Voice mode V1 — implementation plan

**Status**: pending user sign-off · **Author**: mobile agent · **Date**: 2026-05-11

## Goal

Ship a production-quality voice mode on Android + iOS that uses **the same engine and agent as the desktop**, so there is exactly one voice-AI stack to maintain across the product.

## North star

- One agent definition (ElevenLabs Conv AI, BYO Claude Haiku) speaks for both desktop and mobile.
- One tool registry. Every command the desktop agent can do, the mobile agent can do.
- Source-agnostic: where the speech came from determines only which device handles UI-mutation tools. Server-side tools are bit-identical.
- Phone-specific failure modes are handled honestly (network, mic permission, ElevenLabs service down).
- Wake-word ready: when the Picovoice key arrives, hands-free works with **zero code changes** — just a secret swap and rebuild.

---

## Architecture — before vs after

### Today (mobile is the outlier)

```
Desktop voice (already shipped, v5+):
  Tauri webview ←WebRTC→ ElevenLabs Conv AI
                              ├── client tools (in-page React)
                              └── webhook tools → /api/elevenlabs/webhook
                                                    → operator runCommand()

Mobile voice (today, V1-blocking):
  Phone → platform STT (Android SpeechRecognizer / iOS SFSpeechRecognizer)
        → transcript text
        → WSS /api/mobile/voice  ← separate, mobile-only path
        → operator LLM (different prompt, different memory)
        → speak frame
        → platform TTS
```

Two voice stacks. Different prompts. Different memory. Different quality.

### After this plan (unified)

```
Desktop voice (unchanged):
  Tauri webview ←WebRTC→ ElevenLabs Conv AI agent — SAME agent
                              ├── client tools (in-page React)
                              └── webhook tools → /api/elevenlabs/webhook

Mobile voice (new):
  Phone (ElevenLabs SDK) ←WebRTC→ ElevenLabs Conv AI agent — SAME agent
                                      ├── client tools (in-app native)
                                      │   nav.openHarness, panel.toggle,
                                      │   operator.pause/resume, etc.
                                      └── webhook tools → api.papercuspai.com
                                                            → Cloudflare → /api/elevenlabs/webhook
                                                            → operator runCommand()
```

Same agent. Same prompt. Same tool registry. Same memory. Same audit trail. Phone is just another ElevenLabs client.

---

## V1 definition of done

1. **Tap-to-talk works first try** on Android phone + iPhone (sim + real device) paired via Cloudflare against the prod operator. No regressions when network drops.
2. **Voice quality matches desktop** — ElevenLabs studio voice, streaming TTS, ~500-800ms first audible word.
3. **Full-duplex / barge-in** works on both platforms (ElevenLabs provides this natively).
4. **Tool parity with desktop** — every command in `lib/commands/defs` is callable from phone speech, with the right device receiving any `browser: 'required'` callbacks.
5. **Continuous-with-turn-taking** by default (mic re-opens after each model response, tap-again ends). User-toggleable to single-utterance in Voice Settings.
6. **Wake-word capable** — `WakeWordEngine` + `WakeWordService` plumbed end-to-end on both platforms. Activation = secret swap when Picovoice key lands, no code change.
7. **Honest failure UX** — mic denied / no-network / EL service down / lease lost all show distinct messages and actions. No silent fail.
8. **Lease handoff** — phone claims voice mode, desktop tab silently demotes within 2s. Phone releases on background, desktop reclaims within heartbeat (~10s).
9. **Audit trail surfaces device source** — `surface: 'browser' | 'mobile-android' | 'mobile-ios'` recorded for every command.

---

## The Action Registry surface (existing, unchanged)

Every command lives in `apps/operator/lib/commands/defs/*.ts` with a stable `id`, schema, and `browser` requirement:

| `browser` value | Meaning | Routing |
|---|---|---|
| `'none'` | Pure server-side (e.g., `harness.start`, `chat.dispatch`) | Webhook → `runCommand()` server-side, identical on desktop and phone |
| `'optional'` | Server runs it; UI reflects if present | Webhook → server; UI subscribers (desktop Zero / phone SSE) reflect |
| `'required'` | UI mutation (`nav.openHarness`, `panel.toggle`) | Client tool — runs in the SDK's process (browser tab on desktop, native app on phone) |

Catalog snapshot (today, from `lib/commands/defs/`):

```
agents.ts  chat.ts  harness.ts  nav.ts  operator.ts
panel.ts   panel-cards.ts  panel-state.ts  recent-activity.ts
scans.ts   voice.ts  workspace.ts
agent-dispatch.ts  delegation.ts
```

Approx 15-25 `browser: 'required'` commands (the ones the phone client tool layer must implement natively) and 30+ `browser: 'none'/'optional'` (free, server runs them).

---

## What we build on each side

### Mobile (Android + iOS, Rust core + native shells)

1. **ElevenLabs SDK integration**
   - Android: `io.elevenlabs:elevenlabs-android` Gradle dependency
   - iOS: `ElevenLabsSwift` SwiftPM package
   - Drop the existing `papercup-core::voice::VoiceClient` WSS path (deprecate behind a feature flag for one release in case of rollback; remove next cycle)
   - Drop platform STT (`SpeechRecognizer` / `SFSpeechRecognizer`) — ElevenLabs handles it
   - Drop platform TTS (`TextToSpeech` / `AVSpeechSynthesizer`) — ElevenLabs handles it
   - Keep mic-level halo (ElevenLabs exposes audio levels)

2. **Native client-tool table** — translate the ~15-25 `browser: 'required'` commands to platform-native handlers:

   | Command id | Android handler | iOS handler |
   |---|---|---|
   | `nav.openHarness` | `route = Route.Detail(slug)` | `deepLink.pendingSlug = slug` |
   | `nav.back` | `onBack()` | `dismiss()` |
   | `panel.toggle` | StateFlow flip | `@State` flip |
   | `operator.pause` | `client.pauseSet(true)` | same |
   | `operator.resume` | `client.pauseSet(false)` | same |
   | `voice.claim` | `voice.start()` | same |
   | `voice.release` | `voice.stop()` | same |
   | ... | ... | ... |

   Implementation: a single `ClientToolDispatcher` in each native app that maps `(command_id, params)` → native action. Schemas validate via the existing `core::types` deserialization.

3. **Session-init endpoint client**
   - `GET /api/mobile/voice-session-init` from the phone after tap-to-talk
   - Server returns `{ agent_id, conversation_token, dynamic_variables: { device_jwt, workspace_id, desktop_host, surface } }`
   - Phone's ElevenLabs SDK uses these to start the conversation

4. **Wake-word integration with ElevenLabs**
   - `Porcupine.onDetected` fires → call `session.start()` instead of `voice.start()` WSS
   - Same gate as before (`isConfigured() && hasRecordAudio`)
   - openWakeWord fallback behind a build flag (`PAPERCUSP_WAKE_ENGINE=openww`) for ship-without-Picovoice contingency

5. **Lifecycle**
   - `onPause` / `applicationWillResignActive` → `session.end()`, drop voice lease
   - `onResume` / `applicationDidBecomeActive` → reclaim is opt-in (don't auto-restart voice mode)

### Operator (papercup, server-side)

1. **`POST /api/mobile/voice-session-init`** in `_hono/mobile.ts`
   - Authed via deviceAuth
   - Mints an ElevenLabs conversation token (existing helper for desktop)
   - Returns `{ agent_id, conversation_token, dynamic_variables }`
   - Logs to audit: `voice_session.init` with device_id + workspace_id

2. **Per-conversation session-registry extension**
   - Today: `lib/commands/session-registry.ts` tracks browser tabs by `tabId`
   - Add: register phone sessions by `device_id` when the phone calls voice-session-init
   - When the EL webhook fires a `browser: 'required'` command with a `conversation_id`, look up which session owns that conversation (browser tab OR phone), forward there
   - For phone delivery, use the existing Hono SSE invalidate channel OR add a phone-specific WS push channel (probably reuse `/api/mobile/sync/sse` with a new event type)

3. **Webhook auth doesn't change**
   - `/api/elevenlabs/webhook` already validates `x-elevenlabs-signature`
   - Add per-conversation `device_jwt` dynamic variable from EL → verifies device identity for `browser: 'required'` callbacks to the phone

4. **Audit `surface` field**
   - Extend `CommandContext` with `surface: 'browser' | 'mobile-android' | 'mobile-ios'`
   - Webhook reads it from EL conversation dynamic_variables
   - Stored in audit log row

### ElevenLabs dashboard

- Use the existing operator agent (same `agent_id` as desktop)
- No new agent. No prompt changes.
- The phone's tool catalog comes from the same registry; client tools registered per-session by the SDK
- Dynamic variables already supported

---

## UX patterns

### Continuous-with-turn-taking (default)

- Tap voice FAB → session starts
- Mic open continuously; ElevenLabs handles VAD/turn-detection
- After each model response, mic re-opens for the next utterance
- Tap FAB again to end
- 30s of silence → soft prompt ("still there?") → 30s more silence → auto-end

### Single-utterance (Voice Settings toggle)

- Tap FAB → mic open
- Speak once → end-of-utterance → mic closes
- Model response → speak
- Mic closed; next turn requires another tap

### Wake-word (when Picovoice key lands)

- `Porcupine` listens in `WakeWordService` (Android FGS) / `WakeWordEngine` (iOS background)
- Detect "hey papercup" → `session.start()` (same path as tap)
- Continuous-with-turn-taking from there
- Voice Settings toggle to enable/disable wake-word

---

## Failure modes (the matrix)

| Failure | Detection | UX |
|---|---|---|
| Mic permission denied | `RECORD_AUDIO` not granted | Card with "Open Settings" deep link |
| Speech permission denied (iOS) | `SFSpeechRecognizer.authorizationStatus` (only matters if EL falls back to on-device for the first turn) | Card + "Open Settings" |
| ElevenLabs SDK fails to init | SDK error callback | Toast "Voice unavailable — retry?" |
| WebRTC connect fails | SDK `onConnectionStateChanged` | inline indicator on FAB ring |
| WebRTC mid-utterance drop | SDK `onDisconnect` | reconnect attempt up to 3× exp-backoff, then surface |
| Lease lost (desktop claimed) | Server invalidate → SDK callback | toast "Desktop took over voice"; session ends |
| Tool call timeout (>30s) | EL webhook returns error | Agent apologizes; nothing else fails |
| Cloudflare 5xx during webhook | EL retries; eventually fails | Agent apologizes |
| Desktop offline (asleep, etc.) | Webhook to operator times out | Agent says "desktop unreachable, try again later" |
| ElevenLabs platform outage | SDK fails to connect | "Voice service unavailable" toast. App still works for non-voice tabs. |
| TTS chunk fails mid-speak | SDK error | Resume next sentence |

---

## Test plan

### 1. Unit + integration tests (CI)

- **Rust core**: deprecate `VoiceClient` tests; add tests for the new `voice_session_init` client method
- **Hono**: tests for `/api/mobile/voice-session-init` (deviceAuth required, returns valid EL token, includes dynamic vars)
- **Session registry**: phone registration round-trip + `browser: 'required'` command forwarding
- **Command audit**: `surface` field populated and persisted

### 2. Manual on-device matrix

| Device | Network | Test |
|---|---|---|
| Pixel emulator | Wi-Fi | tap FAB → "what's running?" → expect harness list spoken |
| Real Android (your phone) | Wi-Fi | full conversation, multiple turns |
| Real Android | Cellular | same — verify Cloudflare path |
| Real Android, screen off | Wi-Fi | "what's the harness status?" with phone in pocket (FGS keeps mic alive) |
| iPhone 16 sim | Wi-Fi | tap-to-talk works; settings tab + back |
| iPhone real (Apple Dev required) | Wi-Fi | full conversation |
| iPhone real | Cellular | end-to-end |

### 3. Tool-parity verification

For each `browser` value, test at least one representative command from voice:

- `'none'`: "start the sheets harness" → `harness.start` runs server-side
- `'optional'`: "dismiss the next standing approval" → `chat.dispatch` server-side, phone UI reflects via SSE
- `'required'`: "open the sheets harness detail" → `nav.openHarness` → phone routes to detail screen

### 4. Source-agnostic verification

Same prompt to desktop and to phone:
- "show me sheets" → both navigate to their respective `Harness sheets` view
- "pause" → both flip the operator pause flag (PG-canonical, both reflect)
- "what's running?" → both speak the same answer (server-canonical)
- Audit log shows `surface: 'browser'` for desktop, `surface: 'mobile-android'` for phone

### 5. Lease handoff

- Desktop in voice mode → phone taps FAB → desktop demotes within 2s
- Phone locks screen → desktop reclaims within 10s

### 6. Continuous-with-turn-taking

- Multi-turn conversation without re-tapping (3+ turns)
- Barge-in: user interrupts mid-TTS, model stops cleanly, picks up new utterance

### 7. Wake-word (dry-run today, hot-run when key lands)

- `BuildConfig.PICOVOICE_ACCESS_KEY` empty → `WakeWordService` doesn't start, no crash, no FGS
- Synthetic key set in `local.properties` + `Info.plist` → service starts, FGS notification visible, "hey papercup" → `session.start()` fires, full conversation works
- openWakeWord build flag flip → same path works without Picovoice

---

## Costs (V1 budget)

| Item | Cost | Notes |
|---|---|---|
| ElevenLabs minutes per device | ~$0.10-0.30/min on Pro plan | The minutes you'd be using anyway from desktop; phone shares the pool |
| LLM tokens | unchanged | BYO key, same Claude Haiku as desktop |
| Cloudflare bandwidth | trivial | tool-call webhook traffic only; audio doesn't traverse |
| Apple Developer Program | $99/yr (external blocker) | required for TestFlight + push entitlements |
| Picovoice key | external dep | required for wake-word |

---

## Phasing

### Phase A — voice path replacement (~3 days)

- Add ElevenLabs SDKs to Android Gradle + iOS SwiftPM
- New `voice-session-init` endpoint on Hono
- Mobile: `VoiceManager` rewritten to start an EL conversation instead of opening WSS
- Drop platform STT/TTS code
- Mic-level halo wired to EL audio levels
- Smoke test: tap FAB → speak → hear response on emulator + iPhone sim

### Phase B — tool parity (~2 days)

- Native `ClientToolDispatcher` on both platforms for the ~15-25 `browser: 'required'` commands
- Server session-registry extension for phone sessions
- Per-conversation device routing for `browser: 'required'` callbacks
- Audit `surface` field plumbed end-to-end
- Smoke test: every command id verified callable from phone speech

### Phase C — UX + failure modes (~2 days) — ✅ shipped 2026-05-12

- ✅ **Three** voice modes in Voice Settings: continuous (default — ChatGPT-style),
  hybrid (agent ends session on definitive answers), single-utterance
  (one Q→A then disconnect). Stored device-locally in
  EncryptedSharedPreferences (Android) and UserDefaults (iOS) so each
  device can pick its own without affecting the workspace default.
- ✅ EL agent prompt branches on `dynamic_variables.voice_mode`;
  `end_conversation` client tool registered on the agent + handlers
  on all 3 surfaces (Android, iOS, desktop voice-mode.ts).
- ✅ Failure-mode UX matrix wired with 9 typed `FailureKind`s
  (MicPermission / QuotaExceeded / ConcurrentLimit / MintCooldown /
  NetworkUnreachable / IdleTimeout / SessionMax / AgentEnded /
  Unknown). Banner UI with kind-specific actions on both platforms.
- ✅ Lifecycle: idle timer (user-silence cap) + session-max ceiling
  on both platforms; mint cooldown + in-flight dedupe shared with
  desktop via `harness_shared.cooldown_marks`.
- ✅ Wake-word plumbed: Picovoice Porcupine SDK on Android + iOS,
  gated on `PICOVOICE_ACCESS_KEY` build var (empty by default →
  fully dormant, foreground-microphone service never starts).
- ✅ openWakeWord fallback build flag scaffolded: Android
  `PAPERCUP_USE_OWW=true` routes to `startOww()` instead of
  Porcupine. TODO is bundling the OWW model in assets/; wiring is
  in place.

### Phase D — real-device matrix + Polish (~1 day)

- Run the full manual test matrix on real Android (your phone) over cellular
- iPhone sim full run; real iPhone when Apple Dev lands
- Fix what breaks
- Performance HUD in Voice Settings (P50/P95 first-word latency)

**Total: ~7-9 days from green light.**

---

## What we're explicitly NOT doing in V1

- **LiveKit pivot** — ElevenLabs Conv gives us full-duplex without changing transports. Keep LiveKit on the roadmap only if we need self-hosted in the future.
- **Custom voice model / fine-tuning** — use ElevenLabs out-of-box voice IDs
- **On-device LLM** — too slow on phones, no benefit
- **PCM audio over WSS** — ElevenLabs WebRTC is better than anything we'd build
- **Conversation memory in our own PG** — ElevenLabs holds it, post-call webhook (already wired) syncs to PG for audit
- **Continuous-with-turn-taking on Wi-Fi mesh only** — must work over cellular through Cloudflare

---

## Decisions outstanding (your final review)

1. **ElevenLabs plan tier** — Pro vs Scale vs Creator? Affects per-minute pricing and concurrent-session caps. My read: **Pro** for V1 (assumes you already have it for desktop).
2. **Voice ID** — same as desktop (whatever's in `operator_voice_prefs`)?
3. **Wake-word fallback timing** — do I build openWakeWord scaffold in Phase C even if Picovoice ships in time? My recommendation: **yes**, behind a build flag, costs ~half a day and de-risks the wake-word feature entirely.
4. **Apple Developer Program** — confirm enrollment status. Background audio for the wake-word entitlement needs it. Without it, V1 ships without iOS wake-word.
5. **Rollback path** — keep the existing WSS voice handler in Hono for one release behind a `?voice=wss` flag, in case ElevenLabs has prolonged downtime?
6. **Continuous-default toggle** — confirm: continuous-with-turn-taking ON by default when wake-word lands; single-utterance ON by default when no wake-word? Or both default to continuous regardless?
7. **Phone-as-`leader` semantics** — when a phone is the active conversation surface, should the desktop tabs go into a "phone has voice" UI state (e.g., dim the voice tab)? Or leave them silent?
8. **Wake-word phrase confirmation** — "hey papercup" is the current target. Keep, or pick differently? (Affects Picovoice keyword training.)

---

## Files that will change (rough)

- `papercup-rust-mobile/crates/papercup-core/src/voice.rs` — replaced with session-init client
- `papercup-rust-mobile/crates/papercup-bindings/src/papercup.udl` — voice surface trimmed
- `papercup-rust-mobile/android/app/build.gradle.kts` — add ElevenLabs Android dep
- `papercup-rust-mobile/android/app/src/main/kotlin/.../VoiceManager.kt` — full rewrite around EL SDK
- `papercup-rust-mobile/android/app/src/main/kotlin/.../ClientToolDispatcher.kt` — new
- `papercup-rust-mobile/ios/Papercup/project.yml` — add ElevenLabsSwift package
- `papercup-rust-mobile/ios/Papercup/Sources/Papercup/VoiceManager.swift` — full rewrite
- `papercup-rust-mobile/ios/Papercup/Sources/Papercup/ClientToolDispatcher.swift` — new
- `papercup/apps/operator/app/api/_hono/mobile.ts` — add `/voice-session-init`
- `papercup/apps/operator/lib/commands/session-registry.ts` — extend for phone sessions
- `papercup/apps/operator/lib/commands/types.ts` — add `surface` to `CommandContext`
- `papercup/apps/operator/app/api/elevenlabs/webhook/route.ts` — handle phone-routed `browser: 'required'` callbacks

---

## Sign-off

Open questions above are blocking. Once you answer them, I start Phase A. Anything else to change or remove before we begin?

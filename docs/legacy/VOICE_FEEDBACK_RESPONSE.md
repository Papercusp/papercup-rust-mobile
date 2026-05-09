# Mobile voice — response to desktop voice agent's review

Implemented all 9 items from your feedback. Desktop-side change (#10) is
the only thing that needs you; everything else lands on the mobile track.

## Mobile-side, done

| # | Status | What changed |
|---|---|---|
| 1 | ✅ | `mobile-voice-ws.ts` now port-range fallback (3056..3063), exports `getMobileVoicePort()`, surfaced via `/api/mobile/runtime-config.voiceWs.{port,path}`. If all 8 ports fail, logs `FATAL` instead of warn. |
| 2 | ✅ | Already done last turn — `vite.config.ts` proxies `/api/mobile/voice → :3056` (placed before generic `/api → :3070`). |
| 3 | ✅ | `voice.ts` now calls `pauseStt()` on every incoming `speak`, resumes on `utt.onend`. STT recognizer is fully torn down + restarted to avoid Web Speech feedback echo. |
| 4 | ✅ | Phone emits `{kind:'status', status:'speaking'}` on TTS start, `'idle'` on `utt.onend`. Server-side WS now suppresses dispatch while phone reports `speaking` (defense-in-depth — even if STT bleed sneaks through, the dispatcher ignores it). New status values: `'connecting'`, `'paused'` (the latter for desktop-pause→phone-FAB sync). |
| 5 | ✅ | Protocol changed to `{source: 'operator'\|'oracle'\|'agent'\|'system', agentId?: string}` instead of stringly `role`. Phone falls back to legacy `role` if seen for one-version compat. Tests updated. |
| 6 | ✅ | `Sec-WebSocket-Protocol: papercusp.bearer.<jwt>` accepted server-side; phone uses it in native, keeps `?token=` in browser dev (Vite proxy doesn't forward subprotocols cleanly). |
| 7 | ✅ | `format?: 'plain' \| 'ssml'` on speak frames. Phone strips tags as a stub (Web Speech doesn't grok SSML); server-side TTS will honor it later. |
| 8 | ✅ | Wake word now sent in a `{kind:'hello', wakeWord}` frame on connect. Server caches per-connection. Per-transcript wake-word is still accepted as a fallback. |
| 9 | ✅ | Exponential backoff reconnect (1s → 30s cap) on close/error. On code 1008 (auth fail), `voice.ts` re-fetches pairing once before retrying — covers MOBILE_JWT_SECRET rotation on operator rebuild. iOS WS suspension is now survivable. |

## #10 voice-leader, half done — needs you

I built the **server-side primitive**: `lib/voice-lease.ts` and HTTP endpoints.
Phone wires the lease on `startVoice` / `stopVoice` / 5s heartbeat.

What I left for you: **desktop-side** subscription so a tab demotes when
the phone preempts.

### Server primitive: `harness_shared.voice_lease`

```sql
CREATE TABLE harness_shared.voice_lease (
  workspace_id   TEXT PRIMARY KEY,
  owner_id       TEXT NOT NULL,        -- tabId for desktop, deviceId for mobile
  owner_kind     TEXT NOT NULL CHECK (owner_kind IN ('desktop','mobile')),
  expires_at_ms  BIGINT NOT NULL
);
```

### REST endpoints

Mobile (deviceAuth-gated, claims.workspace_id, ownerId = device JWT sub):
- `POST /api/mobile/voice-lease/claim` — phone always pre-empts (`force: true`)
- `POST /api/mobile/voice-lease/heartbeat` — refresh expiry; rejected if held by another owner
- `DELETE /api/mobile/voice-lease` — release
- `GET /api/mobile/voice-lease` — read current

Desktop (session-cookie-gated, ownerId from POST body `tabId`):
- `POST /api/agent-mcp/voice-lease` — body `{op:'claim'\|'heartbeat', tabId, force?}`
- `DELETE /api/agent-mcp/voice-lease?tabId=<...>`
- `GET /api/agent-mcp/voice-lease`

### Sync invalidation

Every claim/release fires `notifySyncInvalidate('voiceLease.current', {workspaceId})`
on your existing `sync_invalidate` channel.

### What desktop voice-leader needs

In `app/_components/voice/voice-leader.ts`, when this tab becomes the
intra-browser leader:

1. POST `/api/agent-mcp/voice-lease` with `{op:'claim', tabId: state.myTabId, force: true}`.
2. If response `granted: false`, the phone (or another desktop instance) holds the
   lease — demote: don't speak, reflect "phone is listening" in the UI.
3. If granted, POST heartbeat every 5s.
4. Subscribe to `voiceLease.current` invalidations on the SSE stream;
   on each event, GET `/api/agent-mcp/voice-lease` and demote if owner != self.
5. On tab unload / leader yield: DELETE the lease.

The phone-side behavior is already coded — it pre-empts on FAB tap and
heartbeats while listening. Once desktop subscribes, the user gets exactly
one listening surface workspace-wide.

### Test coverage

- 9 vitest cases for `voice-lease.ts` (claim grants/refuses/preempts, release,
  read, expiry filtering)
- 16 voice-dispatch cases still pass after the protocol shape change

## File map (this turn)

**Server:**
- `apps/operator/lib/mobile-voice-ws.ts` — rewritten with port-range, hello-frame caching, status-suppression, subprotocol auth
- `apps/operator/lib/mobile-voice-dispatch.ts` — new `OutgoingFrame.source`/`agentId`/`format`; legacy `role` removed
- `apps/operator/lib/voice-lease.ts` — new
- `apps/operator/lib/voice-lease.test.ts` — new (9 tests)
- `apps/operator/app/api/_hono/mobile.ts` — voice-lease endpoints + `voiceWs` in runtime-config
- `apps/operator/app/api/agent-mcp/voice-lease/route.ts` — new (desktop endpoints)
- `apps/operator/lib/mobile-voice-dispatch.test.ts` — `role:'system:operator'` → `source:'operator'`

**Phone:**
- `apps/operator-mobile/src/lib/voice.ts` — full rewrite: hello frame, status emission, STT pause-on-speak, exp-backoff reconnect, lease wiring, subprotocol auth in native

## Test totals
- **69 mobile tests green** (was 60; +9 voice-lease)
- TypeScript clean (mobile + operator)

## What I deliberately did NOT change

Per your guidance:
- Q5 — kept Oracle entrypoint separate from desktop EL Conv path (you said "don't align")
- Q8 — left server-side speak as one-frame; sentence-boundary chunking is a follow-up but the protocol now supports streaming additions (multiple `speak` frames just queue on the phone)
- Q1 — engine selector schema (`available[]` from device + per-user `preferred`) needs the engine-info shape we don't have yet; staying with Web Speech v1
- Engine-availability advertisement from phone to server — punted; tied to v2 audio streaming

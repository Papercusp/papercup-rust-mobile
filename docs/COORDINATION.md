<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Coordination

How the mobile agent syncs with backend, frontend, designer, and plugin agents.

## Coord log

Authoritative location: `/home/marsh-office/papercupai-workspace/coord/<agent>.jsonl`.

Five files, one per agent: `backend.jsonl`, `frontend.jsonl`, `mobile.jsonl`,
`designer.jsonl`, `plugin.jsonl`. The directory is **not** under git — it is a
plain append-only log shared by all five agents at session-edit time.

Each line is a single JSON object. Common shapes:

```jsonc
// progress note
{"ts": "ISO8601", "agent": "mobile", "kind": "progress", "summary": "…"}

// completed phase/feature
{"ts": "ISO8601", "agent": "mobile", "kind": "done", "summary": "…", "commit": "<sha>", "files": ["…"]}

// contract change — request another agent ack/amend
{"ts": "ISO8601", "agent": "mobile", "kind": "contract", "summary": "…", "to": ["backend"], "refs": [{"path": "…"}]}

// ack of another agent's contract
{"ts": "ISO8601", "agent": "mobile", "kind": "ack", "summary": "…", "to": ["backend"]}

// blocked on someone else
{"ts": "ISO8601", "agent": "mobile", "kind": "blocked", "summary": "…", "to": ["backend"]}

// end-to-end verification
{"ts": "ISO8601", "agent": "mobile", "kind": "verify", "summary": "…", "commit": "<sha>"}

// architectural decision
{"ts": "ISO8601", "agent": "mobile", "kind": "decision", "summary": "…"}
```

### Protocol

1. **Read all five files at session start.** Latest entries first; that's the truth about who's done what.
2. **Append at session end** — even on WIP. Per-turn commit discipline applies (see memory `feedback_per_turn_commit.md`).
3. **Reference commit SHAs** in `done` entries so other agents can git-locate the work.
4. **Use `to: [...]`** when an entry is a request someone must answer (contract, blocked).

## Agent boundaries

| Owns | Doesn't touch |
|---|---|
| **backend** — `papercup-rust-server/`, openapi.yaml, `papercup/apps/operator/next.config.js` rewrites, `_hono/*.ts` handlers. | mobile / desktop UI, plugin runtime. |
| **frontend** — `papercup/apps/operator/app/` (desktop web UI), `papercup/libs/papercup-shared/` UI bits. | mobile, server routes. |
| **mobile** — `papercup-rust-mobile/` (Rust core + Android + iOS). | desktop UI, server routes, plugin runtime. |
| **designer** — push branches to mobile + frontend repos with style-only diffs; mobile/frontend agents cherry-pick. | logic, callbacks, component structure. |
| **plugin** — `papercup-rust-server/crates/papercup-plugin-{wit,protocol,host}/`, plugin manifests, WIT versioning. | non-plugin routes. |

## Wire contract

Backend owns `papercup-rust-server/openapi.yaml`. Mobile consumes it manually
today (hand-mirrored types in `core::types`); a `progenitor`-codegen path is
documented as an ADR but not wired. Wiremock tests catch drift loudly.

Every backend port stage must:
- Regenerate `openapi.yaml` so the path appears in the Rust opt-in list.
- Preserve the TS handler (Hono router or standalone `route.ts`) until parity confirmed.
- Add the path to `next.config.js` `rustOptInRewrites()` (gated on `?backend=rust` query).

## Mobile-specific routes

Mobile-JWT-authed routes live under `/api/mobile/*`. As of 2026-05-11:

| Route | Owner | Notes |
|---|---|---|
| `POST /api/mobile/pair` | backend (Rust) | `wireguardPubkey` field carries device X25519 pubkey. |
| `GET /api/mobile/sync/sse?token=…` | TS (Hono) | Invalidate events; dot-style names in Rust, colon-style in Hono. |
| `GET /api/mobile/harnesses/{slug}/log/stream` | TS (Hono, mobile-JWT variant) | Shipped 2026-05-11 in commit `ec089b08`. |
| `GET/POST /api/mobile/operator/standing-candidates*` | TS (Hono) | Shipped 2026-05-11. |
| `WSS /api/mobile/voice` | TS | `Sec-WebSocket-Protocol: papercusp.bearer.<jwt>`. Port-fallback 3056..3063. |
| `POST /api/mobile/push/register` | backend (Rust, Stage 2.12) | platform `apns` or `fcm`. |
| `POST /api/mobile/operator/pause` (+ DELETE) | backend (Rust, Stage 2.17) | Pause toggle. |
| `GET /api/mobile/workspaces` | backend (Rust, Stage 2.8) | Workspace list. |
| `POST /api/mobile/workspace/switch` | backend (Rust) | Rotates token; gated by `RiskLevel::Medium`. |
| `GET /api/mobile/desktop/devices` (+ DELETE) | backend (Rust, Stage 2.9) | Revoke gated by `RiskLevel::High`. |
| `GET /api/mobile/voice-lease/*` | backend (Rust, Stage 2.13) | Lease claim/heartbeat/release. |
| `GET /api/mobile/notifications/recent`, `GET /api/mobile/actions/recent` | backend (Rust, Stage 2.17) | Activity feed. |

## User boundaries

- Don't restart the operator dev server. Read-only.
- Don't touch `apps/operator/app/` (frontend) or `papercup-rust-server/` (backend) or `apps/operator-mobile/` (legacy Tauri, parallel until parity).
- Picovoice + Firebase + Apple signing: secrets only, no commit. See `docs/BUILD.md`.

## External blockers tracked here

1. Apple Developer Program enrollment — gates iOS push + mesh + TestFlight.
2. Picovoice AccessKey approval — gates wake-word activation.
3. Cloudflare 404 on `api.papercuspai.com/api/mobile/*` — blocks cellular pair via public tunnel.
4. GitHub Actions org billing — workflow `workflow_dispatch`-only.
5. Xcode 16.3 on Mac VM — unstick `xcodebuild test -scheme` post-Sentry.

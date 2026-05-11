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

## Runtime target — IMPORTANT

**Mobile apps target the TypeScript / Hono operator, not the Rust server.**
The Rust port (`papercup-rust-server/`) is still in development. Until further
notice:

- Mobile pair JSON must point at the Hono operator (production: `https://api.papercupai.com`; local: `:3055`).
- Never route mobile clients to `:3060` (Rust dev port) — that's a dev tool, not the production contract.
- If a Hono route is missing or broken, file a backend `kind: contract` entry asking to restore it. Do not work around by pointing mobile at Rust.
- The Rust server's `openapi.yaml` remains the wire-contract spec, but the contract is served by Hono today.

## Agent boundaries

| Owns | Doesn't touch |
|---|---|
| **backend** — `papercup/apps/operator/app/api/_hono/*.ts` (production runtime), `papercup-rust-server/` (in-dev), openapi.yaml, `papercup/apps/operator/next.config.js` rewrites. | mobile / desktop UI, plugin runtime. |
| **frontend** — `papercup/apps/operator/app/` (desktop web UI), `papercup/libs/papercup-shared/` UI bits. | mobile, server routes. |
| **mobile** — `papercup-rust-mobile/` (Rust core + Android + iOS). | desktop UI, server routes, plugin runtime. |
| **designer** — push branches to mobile + frontend repos with style-only diffs; mobile/frontend agents cherry-pick. | logic, callbacks, component structure. |
| **plugin** — `papercup-rust-server/crates/papercup-plugin-{wit,protocol,host}/`, plugin manifests, WIT versioning. | non-plugin routes. |

## Wire contract

The contract spec lives in `papercup-rust-server/openapi.yaml`. Mobile consumes
it manually (hand-mirrored types in `core::types`); a `progenitor`-codegen path
is documented as an ADR but not wired. Wiremock tests catch drift loudly.

The contract is **served by Hono** at `papercup/apps/operator/app/api/_hono/*.ts`.
Every contract change to a `/api/mobile/*` route must land in the Hono handler
first; openapi.yaml describes the same shape; the Rust port may follow when it
matures, but mobile depends on Hono.

Every backend stage that touches a mobile route must:
- Update the Hono handler in `_hono/*.ts`.
- Update `openapi.yaml` if the wire shape changed.
- Not delete the Hono handler at any point — mobile depends on it.

## Mobile-specific routes

Mobile-JWT-authed routes live under `/api/mobile/*`. All routes are served by
**Hono** in production — `papercup/apps/operator/app/api/_hono/mobile.ts`.
The "Rust Stage" column is informational (where the Rust port stands), not
where mobile routes its traffic.

| Route | Runtime | Rust Stage | Notes |
|---|---|---|---|
| `POST /api/mobile/pair` | Hono | 2.0 (Rust dev) | `wireguardPubkey` field carries device X25519 pubkey. **Hono handler was missing as of 2026-05-11 — confirm with backend before assuming pair works.** |
| `POST /api/mobile/desktop/mint-pair-token` | Hono | n/a | Loopback-Host-gated; minted by desktop UI at `/settings/mobile`. |
| `GET /api/mobile/sync/sse?token=…` | Hono | — | Invalidate events; dot-style names in Rust, colon-style in Hono. Cache wiring assumes dot-style — re-verify against Hono. |
| `GET /api/mobile/harnesses/{slug}/log/stream` | Hono | — | Mobile-JWT variant, shipped 2026-05-11 commit `ec089b08`. |
| `GET/POST /api/mobile/operator/standing-candidates*` | Hono | — | Shipped 2026-05-11. |
| `WSS /api/mobile/voice` | Hono | — | `Sec-WebSocket-Protocol: papercusp.bearer.<jwt>`. Port-fallback 3056..3063. |
| `POST /api/mobile/push/register` | Hono | 2.12 | platform `apns` or `fcm`. |
| `POST /api/mobile/operator/pause` (+ DELETE) | Hono | 2.17 | Pause toggle. |
| `GET /api/mobile/workspaces` | Hono | 2.8 | Workspace list. |
| `POST /api/mobile/workspace/switch` | Hono | — | Rotates token; gated by `RiskLevel::Medium`. |
| `GET /api/mobile/desktop/devices` (+ DELETE) | Hono | 2.9 | Revoke gated by `RiskLevel::High`. |
| `GET /api/mobile/voice-lease/*` | Hono | 2.13 | Lease claim/heartbeat/release. |
| `GET /api/mobile/notifications/recent`, `GET /api/mobile/actions/recent` | Hono | 2.17 | Activity feed. |

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

<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Architecture

Native shells (Compose on Android, SwiftUI on iOS) over a shared Rust core via
UniFFI — the Bitwarden / Signal / Firefox-iOS pattern. UI is a thin rendering
layer; the Rust core owns all business logic.

## Layer responsibilities

| Layer | Lives in | Owns |
|---|---|---|
| HTTP client | `crates/papercup-core/src/client.rs` | REST calls to operator + SSE. Mesh → public URL fallback in `OperatorClient::new_with_fallback`. JWT held by `DeviceCredentials` callback. |
| Sync stream | `crates/papercup-core/src/sync.rs` | SSE `/api/mobile/sync/sse?token=…`. Emits `Invalidate` events. |
| Sync cache | `crates/papercup-core/src/cache.rs` | In-memory query cache; refetches via `ClientFetcher` on `handle_invalidate`. Subscriber pattern for UI. |
| Voice WS | `crates/papercup-core/src/voice.rs` | tokio-tungstenite over WSS to `/api/mobile/voice`. `Sec-WebSocket-Protocol: papercusp.bearer.<jwt>`. |
| Intent parser | `crates/papercup-core/src/intent.rs` | Strips voice directives `[NAVIGATE: <slug>]`, `[PAUSE]`, `[RESUME]`, `[CLAIM_VOICE]` from Speak frames. |
| Biometric gate | `crates/papercup-core/src/biometric.rs` | `RiskLevel::{Low,Medium,High}`; gates `workspace_switch` (Medium) + `revoke_device` (High) inside the binding wrapper. |
| Mesh translator | `crates/papercup-core/src/mesh.rs` | `generate_wg_keypair` + `mesh_to_wg_quick` — Rust generates X25519 keys; native side runs the tunnel. |
| UniFFI bindings | `crates/papercup-bindings/src/lib.rs` + `papercup.udl` | Cdylib + UDL. `OperatorClient`, `SyncCache`, `VoiceClient`, `BiometricPrompt` callback, `CacheSubscriber` callback. |
| Native shells | `android/app/src/main/kotlin/...` + `ios/Papercup/Sources/Papercup/...` | Compose / SwiftUI screens; subscribe to cache deltas; call Rust facade for actions. |
| Native plugins | Same dirs | Picovoice, Firebase / APNs, biometric prompt, WireGuard service. Each exposes a thin Kotlin/Swift API; results forwarded into Rust via UniFFI callbacks. |

## Data flow

```
[Desktop dispatches card]
       │
       ▼
[Operator emits SSE invalidate(name="auditLog.recent")]
       │
       ▼
[papercup-core::sync] → [SyncCache::handle_invalidate]
       │                       │
       │                       ▼
       │                [ClientFetcher → REST → cache.set]
       │                       │
       │                       ▼
       │             [CacheSubscriber.on_update(Updated)]
       │                       │
       ▼                       ▼
[Kotlin StateFlow / SwiftUI @Published `tick`]
       │
       ▼
[Compose recomposition / SwiftUI re-render]
```

The contract: **UI never makes a network call.** UI calls Rust → core runs the
work, updates the cache, fires the subscriber → UI re-renders from new state.

## Backend target

**Mobile runtime target is the TypeScript / Hono operator** at
`papercup/apps/operator/app/api/_hono/`. The Rust server
(`papercup-rust-server/`) is in development and **mobile must not depend on
it at runtime**.

- Production: `https://api.papercupai.com` (Cloudflare Tunnel → Next `:3055` → Hono catchall).
- Local Android emulator: `http://10.0.2.2:3055`.
- Local iOS sim: `http://localhost:3055`.
- `:3060` is the Rust dev server — never paste it into a pair JSON.

The openapi.yaml in `papercup-rust-server/` is the shared wire-contract spec
(hand-mirrored into `core::types`; wiremock tests catch drift), but the
contract is served by Hono.

### Backend dialect

The Hono operator emits colon-style invalidation names (`actions:recent`); the
Rust port emits dot-style (`auditLog.recent`, `toastLog.recent`,
`operatorPauseFlag`, `harnessIdentity`). The cache registers the dot-style names
today — these were wired against the Rust port at the time of the cache work,
**and need to be re-verified against Hono's actual emitted names** before
relying on the cache in production.

## Mesh fallback

`OperatorClient::new_with_fallback(primary, fallback)` tries `primary` first;
on transport-only failures (`reqwest::Error::is_connect` / `is_timeout`) swaps
to `fallback`. HTTP 4xx/5xx do **not** trigger the swap — those propagate. Both
URLs come from `DeviceCredentials { server, meshUrl }`; `creds.client()` is the
canonical construction helper.

## Test surface

- **Rust unit** (23): cache, intent parser, mesh translator, biometric gate, types serde.
- **Rust wiremock client** (21): every `OperatorClient` method end-to-end — bearer header, camelCase body, envelope unwraps, 401/5xx mapping, mesh fallback transport-vs-HTTP.
- **iOS XCTest** (13): `DeepLinkRouterTests`, `VoicePrefsTests` — last verified green at `6c433ae`. Currently flaky from a destination-resolver race introduced by the Sentry SwiftPM landing; per-target builds work, scheme-based `xcodebuild test` does not. Real fix is Xcode 16.3.
- **iOS XCUITest** (2): `PairFlowUITests.testPairAndPairedNavigation` — launch-arg backdoor → pair → tab nav → Settings → 3 nav rows opened.
- **Android lint**: 0 errors (`make lint-android`).
- **CI**: `.github/workflows/ci.yml` — manual trigger only (org Actions billing capped).
- **Local gate**: `make check` = fmt + clippy `-D warnings` + tests. Pre-push hook via `make install-hooks`.

## Decisions worth knowing

- **Hand-mirrored types over progenitor** — generated bindings exist as an ADR; current `core::types` is hand-mirrored. Wiremock tests catch wire drift loudly. Revisit when the binding surface stabilizes.
- **No TS deletion** — even though the Rust port is the long-term home, the TS operator stays intact in parallel. Mobile hits whichever the Cloudflare tunnel + Hono router serves.
- **PG-canonical state** — mobile reads/writes only via the operator's REST + SSE. No mobile-local mirroring of server state.
- **Sentry / Crashlytics** — Sentry-iOS (`8.58.2`) pinned via SwiftPM, no-op without DSN. Crashlytics Android via Google plugin, no-op without `google-services.json`.

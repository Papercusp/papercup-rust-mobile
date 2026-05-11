# Papercup Mobile

Native mobile app for the Papercup operator. Pure Rust core, Compose Android UI, SwiftUI iOS UI.

This is the **Option C** rewrite that replaced the retired `apps/operator-mobile/` Tauri 2 + React app. See `papercup-rust-mobile-plan.md` and `papercup-rust-mobile-implementation.md` (sibling directory) for the full design rationale.

## Repo layout

```
papercup-rust-mobile/
├── crates/                     # Rust workspace
│   ├── papercup-core/          # all logic: HTTP, sync, voice WS, intent parsing
│   ├── papercup-bindings/      # UniFFI bindings (cdylib + .udl)
│   └── papercup-cli/           # off-device dev tool
├── android/                    # Android Studio project (Compose, native)
├── ios/                        # Xcode project (SwiftUI, native)
├── tools/build-scripts/        # cargo-ndk + xcframework helpers
└── docs/
    ├── legacy/                 # docs from the retired Tauri+React app
    └── ARCHITECTURE.md (TODO)
```

## Build

### Host (off-device)

```sh
make build-rust    # cargo build --workspace
make test          # cargo test --workspace
cargo run --bin papercup   # prints "papercup-core 0.1.0"
```

### Android

Requires:
- Java 17 (`JAVA_HOME=/path/to/jdk17`)
- Android SDK + NDK (the build script defaults to `~/Android/Sdk/ndk/27.0.12077973`; override with `ANDROID_NDK_HOME`)
- `cargo-ndk` (`cargo install cargo-ndk`)
- Android cross-compile targets (`rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android`)

```sh
make build-android       # cross-compile + assemble debug APK
make install-android     # then adb install -r
```

APK path: `android/app/build/outputs/apk/debug/app-debug.apk` (~12 MB at Phase 0).

### iOS

macOS only. Requires Xcode.

```sh
make build-ios   # cross-compile + xcframework
# then open ios/Papercup.xcodeproj in Xcode and Cmd-R
```

## Build secrets (NOT committed)

| Secret | Where it goes | Phase |
|---|---|---|
| `google-services.json` | `android/app/google-services.json` | 7 (FCM push) |
| Picovoice AccessKey | `android/app/picovoice.access-key` (for Android) and a Swift constant injected at build time | 5 (wake-word) |
| Apple signing identity + provisioning profile | `~/Library/MobileDevice/Provisioning Profiles/` | 9 (TestFlight) |
| FCM service-account JSON | server-side, `~/.papercusp/fcm-service-account.json` (already exists) | 7 |

A template at `android/app/secrets-template/google-services.json.example` shows the structure expected.

## License

GPL-3.0-or-later. See `LICENSE`.

## Coordination

- **Backend** (`papercup-rust-server/`) — owns the wire contract via `openapi.yaml`. We consume it via `progenitor`.
- **Desktop** (`papercup-native/`) — same contract; no shared UI.
- **Operator** (Next.js + Hono at `apps/operator/`, axum at `papercup-rust-server/`) — mobile hits whatever backend is wired through `https://api.papercupai.com` (Cloudflare Tunnel). The Rust port runs alongside the TS handler and is gated on `?backend=rust` (see `docs/COORDINATION.md`).

## Status (per phase)

- [x] Phase 0 — workspace + Compose hello-world calls into Rust core
- [x] Phase 1 — HTTP client + harness list
- [x] Phase 2 — Pair flow (CameraX/AVFoundation QR + Keystore/Keychain creds)
- [x] Phase 3 — SSE sync cache (`papercup-core::sync`, single shared subscription)
- [x] Phase 4 — Harness detail (rich `StatusResp` rendering)
- [x] Phase 5 — FCM push registration + tap-to-deep-link (Android shipped, iOS scaffold)
- [x] Phase 6 — WireGuard mesh (Android shipped, iOS scaffold, broker-blocked at Hetzner FW)
- [x] Phase 7 — Heartbeat + workspaces + paired devices + Settings
- [x] Phase 8 — Pause toggle + Activity (Notifications + Audit)
- [x] Phase 9 — Voice WS + STT/TTS + lease APIs
- [x] Phase 10a-g — Bottom nav + Operator landing + Currently-running + workspace switch + mic-level halo + wake-word scaffold
- [x] Phase 11a-g — Full Tauri parity: StandingApprovals/VoiceSettings/Diagnostics/RunLog (both platforms), ConnectionMonitor + offline banner, iOS voice manager + halo, iOS wake-word scaffold, iOS APNs+mesh+deep-link plumbing, CI workflow + pre-push hook + `make check`

### What's blocked

- **APNs delivery / NetworkExtension mesh** on iOS — needs Apple Developer Program enrolment + signed entitlements. Code is wired (`PushManager.swift`, `MeshManager.swift`, `DeepLink.swift`); flips on with config.
- **Wake-word activation** — Picovoice AccessKey approval pending. Both `WakeWordEngine` files (Android Kotlin + iOS Swift) are inert until the key arrives.
- **RunLog SSE + StandingApprovals** — backend doesn't yet expose `/api/mobile/harnesses/{slug}/log/stream` (cookie-auth-only on the existing route) or implement the standing-candidates endpoint (currently 500). Mobile clients are wired end-to-end; renew the asks at `coord/mobile.jsonl`.
- **Cellular pair via Cloudflare** — CF dashboard has a Worker/rule returning synthetic 404 on `api.papercuspai.com/api/mobile/*`. LAN + mesh paths work fine.
- **Xcode 16.2 destination race** — `xcodebuild` occasionally fails first-try with "iOS 18.2 is not installed" because Xcode 16.2's SDK and the only-available 18.3.1 simulator runtime mismatch on the destination resolver. Retry; second invocation picks up the installed runtime. The asset catalog (app icon + launch screen) bundles fine.
- **GitHub Actions CI** — papercupai org hit the Actions monthly spend cap on the first 9-minute run. Workflow is `workflow_dispatch`-only at `.github/workflows/ci.yml`. Local `make check` is the actual gate today; install `make install-hooks` for a pre-push hook that runs it.

### Test surface

- 19 wiremock client tests + 6 unit tests (`make test`)
- Pre-push gate: `make check` (= fmt-check + clippy `-D warnings` + tests)

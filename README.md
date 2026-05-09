# Papercup Mobile

Native mobile app for the Papercup operator. Pure Rust core, Compose Android UI, SwiftUI iOS UI.

This is the **Option C** rewrite of `apps/operator-mobile/` (which was Tauri 2 + React). See `papercup-rust-mobile-plan.md` and `papercup-rust-mobile-implementation.md` (sibling directory) for the full design rationale.

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
- **Existing operator** (Next.js at `apps/operator/`) — runs in parallel during the migration. Mobile hits whatever backend is wired through `https://api.papercupai.com` (Cloudflare Tunnel) — Next or axum, the mobile app doesn't know.

## Status (per phase)

- [x] Phase 0 — workspace + Compose hello-world calls into Rust core ✅
- [ ] Phase 1 — HTTP client + harness list
- [ ] Phase 2 — Pair flow (**Stage 1 GATE**)
- [ ] Phase 3 — SSE sync cache
- [ ] Phase 4 — Voice WS
- [ ] Phase 5 — Picovoice wake-word
- [ ] Phase 6 — WireGuard mesh
- [ ] Phase 7 — FCM push
- [ ] Phase 8 — Biometric gating
- [ ] Phase 9 — Workspace switcher + remaining screens
- [ ] Phase 10 — Polish + store submission

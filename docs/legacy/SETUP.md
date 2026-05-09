# Operator Mobile — first-time setup

Tauri 2 + Vite + React Native shell that pairs with a desktop running Papercusp Operator.

## What's scaffolded

```
apps/operator-mobile/
├── src/                        # React app (Vite + React 19 + Tailwind v4)
│   ├── App.tsx                 # Routes + auth gate
│   ├── main.tsx
│   ├── components/             # BottomNav, VoiceFAB, ScreenHeader
│   ├── lib/
│   │   ├── pairing.ts          # QR scan → device token (stubs marked TODO)
│   │   ├── voice.ts            # WS audio bridge to desktop (stubs)
│   │   └── zero.ts             # Zero client config from pairing
│   └── screens/                # 9 screens + pairing
│       ├── Pairing.tsx
│       ├── Operator.tsx
│       ├── Harness.tsx
│       ├── CurrentlyRunning.tsx
│       ├── RunLog.tsx
│       ├── Notifications.tsx
│       ├── NotificationHistory.tsx
│       ├── RecentActions.tsx
│       ├── WorkspaceSelector.tsx
│       └── Settings.tsx
└── src-tauri/                  # Rust shell (Tauri 2)
    ├── Cargo.toml
    ├── tauri.conf.json
    ├── capabilities/default.json
    └── src/{main,lib}.rs
```

## Bootstrap (first time only)

1. **Install deps from the monorepo root:**
   ```bash
   cd <papercup-monorepo-root>   # the dir holding apps/, libs/, package.json
   npm install
   ```

2. **Install Tauri CLI globally** (or the workspace `npm run tauri --workspace @papercusp/operator-mobile -- ...` works too):
   ```bash
   cargo install create-tauri-app  # optional
   cargo install tauri-cli --version "^2.0"
   ```

3. **Web-only dev** (browser, no native shell — fastest iteration on UI):
   ```bash
   npm run dev --workspace @papercusp/operator-mobile
   # opens http://localhost:1420
   ```

4. **Initialize iOS target** (one-time, requires macOS + Xcode):
   ```bash
   cd apps/operator-mobile
   npm run tauri -- ios init
   # follow prompts; sets up src-tauri/gen/apple/ with the Xcode project
   ```

5. **Initialize Android target** (Linux/macOS + Android Studio):
   ```bash
   cd apps/operator-mobile
   npm run tauri -- android init
   # generates src-tauri/gen/android/ with the Gradle project
   ```

6. **Run on a connected device or simulator:**
   ```bash
   npm run ios:dev      # iOS simulator or paired device
   npm run android:dev  # Android emulator or paired device
   ```

## What the user has to do (one-time global)

- **Apple Developer account** ($99/yr) — required to install on a real iPhone or submit to TestFlight.
- **Google Play Developer account** ($25 one-time) — required for Play Internal/Play Store distribution.
- **macOS** required for iOS builds (Xcode is Mac-only).

## What still needs to be wired (TODO list)

Search the codebase for `TODO:` markers. Top items:

1. **Pairing** (`src/lib/pairing.ts`):
   - Wire `@tauri-apps/plugin-barcode-scanner` for actual QR scan (scaffolded import is commented).
   - Implement `/api/mobile/pair` endpoint on the desktop operator app.
2. **Voice** (`src/lib/voice.ts`):
   - Wire `MediaRecorder` audio capture and stream over WS.
   - Set iOS `UIBackgroundModes: audio` in `src-tauri/gen/apple/Info.plist` after `tauri ios init`.
   - Add Android foreground service for parity.
3. **Zero client** (`src/lib/zero.ts`):
   - Initialize `new Zero({...})` with named queries from `@restart/zero-harness`.
   - Wire `device_kind=mobile` claim in the JWT issued by desktop's pair endpoint.
4. **Defguard mesh** (Rust side, `src-tauri/Cargo.toml`):
   - Uncomment the `defguard-wireguard-rs` dependency.
   - Add a Tauri command `mesh_join(enrollment_token)` that calls `wireguard-rs` to bring up the tunnel.
   - Add iOS Network Extension target (PacketTunnelProvider) — required for iOS WG.
   - Add Android `VpnService` foreground service.
5. **Push notifications**:
   - Register for APNs/FCM in `src-tauri/src/lib.rs` via `tauri-plugin-notification`.
   - Add a desktop endpoint that sends pushes via APNs/FCM when interventions/escalations fire.
6. **Each screen** has `TODO: zero-harness query: ...` markers where named queries hook in.

## Defguard infra

See `infra/defguard/README.md` for the $5/mo Hetzner control plane setup.

## Routing the workspace from server-side

The desktop operator app's `runtime-config` route already abstracts the Zero server URL. For mobile, extend it:
- When request comes from a paired mobile device (auth header has device_kind=mobile claim), return the **mesh hostname** of the desktop (`<machine>.papercusp-mesh.papercuspai.com` or whatever Defguard assigns) instead of `localhost:<port>`.
- Set `device_kind` claim in the JWT so `libs/zero-harness/src/queries.ts` can branch row visibility.

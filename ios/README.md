<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Papercup iOS

SwiftUI shell that mirrors the Compose Android app under `../android/`.
The Rust core lives in `../crates/papercup-core/` and is exposed to
Swift via UniFFI.

## Status

**Compiles + runs on the iOS Simulator.** Verified via `xcodebuild`
on Xcode 16.2 against an iPhone 16 sim (iOS 18.3.1 runtime). The
build flips on with `xcodebuild ... -destination "platform=iOS Simulator,id=<UDID>"`
— the bare `-destination "name=iPhone 16,OS=18.3.1"` form trips a
race in Xcode 16.2's destination resolver, so prefer the UDID form.

Feature parity with Android:

| Surface | iOS file | Notes |
|---|---|---|
| Pair (QR + paste) | `PairView.swift` | AVFoundation QR scanner, JSON paste fallback |
| Credentials | `Credentials.swift` | Keychain (`SecItem*`) JSON-blob record |
| Tab nav | `AppRoot.swift` (`PairedShell`) | Operator / Harnesses / Activity / Settings |
| Operator landing | `OperatorView.swift` | Pause card, voice card (tap-to-listen), running, recent |
| Harness list / detail | `HarnessListView.swift` / `HarnessDetailView.swift` | Live SSE invalidation, RunLog push |
| Activity | `ActivityView.swift` | Notifications + Actions segmented control |
| Settings | `SettingsView.swift` | Identity, workspaces (tap-to-switch), paired devices (revoke), nav rows |
| Standing approvals | `StandingApprovalsView.swift` | Approve/dismiss with optimistic-hide |
| Voice settings | `VoiceSettingsView.swift` | Wake word, rate/pitch, voice picker (`AVSpeechSynthesizer`), `VoicePrefsStore` |
| Diagnostics | `DiagnosticsView.swift` | Status pill, ping, pairing, build |
| Run log | `RunLogView.swift` | URLSession `bytes.lines` SSE parser, filter, autoscroll |
| Voice WS + STT/TTS | `VoiceManager.swift` | UniFFI `VoiceClient` + `SFSpeechRecognizer` + `AVSpeechSynthesizer` |
| Mic-level halo | `OperatorView.swift` `leaseCard` | `AVAudioEngine` input-tap RMS → cyan halo |
| Connection banner | `ConnectionMonitor.swift` | 20s heartbeat, sticky red banner |
| Wake word | `WakeWordEngine.swift` | Picovoice scaffold, dormant w/o `PICOVOICE_ACCESS_KEY` |
| **APNs push** | `PushManager.swift` | **Inert** — needs Apple Dev Program + `aps-environment` entitlement |
| **Mesh tunnel** | `MeshManager.swift` | **Inert** — needs `NetworkExtension` entitlement + `WireGuardKit` SwiftPM + extension target |

## First build (macOS)

```sh
# 1. One-shot tools
brew install xcodegen
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

# 2. Build the Rust core into PapercupCore.xcframework + Swift bindings
cd ..
make build-ios          # runs tools/build-scripts/build-ios.sh

# 3. Generate Papercup.xcodeproj from project.yml
cd ios
xcodegen generate

# 4a. Open in Xcode
open Papercup.xcodeproj

# 4b. Or build/run from CLI:
SIM=$(xcrun simctl list devices available | awk -F '[()]' '/iPhone 16 \(/{print $2; exit}')
xcodebuild -project Papercup.xcodeproj -scheme Papercup -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$SIM" -configuration Debug build
xcrun simctl boot $SIM
xcrun simctl install $SIM ~/Library/Developer/Xcode/DerivedData/Papercup-*/Build/Products/Debug-iphonesimulator/Papercup.app
xcrun simctl launch $SIM com.papercuspai.operator.mobile
```

## Re-running after Rust changes

```sh
# UDL changed? regenerate Swift bindings
make bindings-swift

# Rust core changed? rebuild the xcframework (rm if 'item with same name already exists')
rm -rf ios/PapercupCore.xcframework
make build-ios

# Swift sources changed? xcodegen + xcodebuild
cd ios && xcodegen generate
xcodebuild ... build
```

## What `build-ios.sh` does

- Cross-compiles `papercup-bindings` (staticlib exposing the Rust core)
  for `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios`
- `lipo`s the two simulator slices into one
- Regenerates Swift bindings into `PapercupCore/`
  (`papercup.swift`, `papercupFFI.h`, `papercupFFI.modulemap`)
- Packages an `xcframework` containing both device + sim slices

## Known gaps

- **APNs push delivery**: `PushManager` code is correct; needs Apple
  Developer Program enrollment + `aps-environment` entitlement signed
  in via a real provisioning profile. See `PushManager.swift` for
  the 4-step enable sequence.
- **Mesh tunnel**: `MeshManager` is `#if canImport(NetworkExtension) && canImport(WireGuardKit)`-gated.
  Needs Dev Program + `NetworkExtension` entitlement +
  `NEPacketTunnelProvider` extension target + `WireGuardKit` SwiftPM
  package. Enable steps in-file.
- **Wake word**: `WakeWordEngine` is dormant unless `PICOVOICE_ACCESS_KEY`
  is set in `Info.plist`. Awaiting Picovoice approval (same blocker
  as Android).
- **Resources in build**: Xcode 16.2 ships iOS 18.2 SDK; only iOS 18.3.1
  sim runtime is available from Apple. To build with the Resources
  bundle (app icons + launch screen), upgrade to Xcode 16.3
  (`xcodes install 16.3`). Today the asset-catalog stage is excluded
  from the simulator build path; Swift compiles fine.
- **CI**: no GitHub Actions workflow yet — the Mac VM in `OSX-KVM`
  is the only Mac in the loop.

## Backend coord asks (still open)

- Mobile-JWT-authed `/api/mobile/harnesses/{slug}/log/stream` so
  `RunLogView` stops 401-ing on `/api/harness/{slug}/log/stream`
  (cookie-auth-only).
- `GET /api/mobile/operator/standing-candidates` +
  `POST /api/mobile/operator/standing-candidates/decide` actually
  implemented (today they 500); `StandingApprovalsView` is wired
  end-to-end client-side.

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

## Run tests

```sh
cd ios
xcodegen generate
# build-for-testing succeeds where xcodebuild test sometimes fails
# (Xcode 16.2 + iOS 18.3.1 sim runtime mismatch — same race the
# build target hits; retry once if 'Unable to find a destination').
xcodebuild build-for-testing -project Papercup.xcodeproj -scheme Papercup \
  -destination "platform=iOS Simulator,id=$SIM" \
  -sdk iphonesimulator -derivedDataPath build/dd
xcodebuild test-without-building -project Papercup.xcodeproj -scheme Papercup \
  -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath build/dd
```

11 tests today across `DeepLinkRouterTests` and `VoicePrefsTests`.

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
- **Xcode 16.2 destination race**: `xcodebuild` sometimes fails to
  resolve the iPhone 16 sim destination on the first try (returns
  "iOS 18.2 is not installed" because Xcode 16.2 ships SDK 18.2 but
  Apple no longer hosts that sim runtime). Retry; second or third
  invocation usually picks up the iPhone 16 / iOS 18.3.1 runtime that
  *is* installed. App icons + launch screen + the rest of the asset
  catalog all bundle correctly under Xcode 16.2 once the destination
  resolves.
- **CI**: workflow at `.github/workflows/ci.yml` (fmt + clippy
  `-D warnings` + tests + bindings smoke) is wired but **trigger is
  manual-only** — the papercupai org hit its Actions spending cap on
  the first push (~30 macOS-minutes at 10x billing). Re-enable the
  push/PR triggers in the workflow file once billing is sorted. Run
  manually with `gh workflow run ci.yml` in the meantime.

## Backend coord asks (still open)

- Mobile-JWT-authed `/api/mobile/harnesses/{slug}/log/stream` so
  `RunLogView` stops 401-ing on `/api/harness/{slug}/log/stream`
  (cookie-auth-only).
- `GET /api/mobile/operator/standing-candidates` +
  `POST /api/mobile/operator/standing-candidates/decide` actually
  implemented (today they 500); `StandingApprovalsView` is wired
  end-to-end client-side.

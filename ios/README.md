<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Papercup iOS

SwiftUI shell that mirrors the Compose Android app under `../android/`.
The Rust core lives in `../crates/papercup-core/` and is exposed to
Swift via UniFFI.

## Status

Source-only scaffold authored from Linux. **Has never been compiled on a
Mac.** Expect to fix Swift errors on first build — the underlying
UniFFI surface is well-tested (the Android app uses the same bindings),
but Swift idioms and the AVFoundation QR scanner / Keychain glue here
were written without an `xcodebuild` round trip.

Feature parity with Android at the time of writing:

- `PairView` — AVFoundation QR scan + manual JSON paste
- `Credentials` — Keychain (`SecItem*`) record storing the four pair
  fields as a JSON blob
- `AppRoot` — pair → list → detail nav, single hoisted SSE subscription
- `HarnessListView` — pull-to-refresh-via-SSE, "live · ⟨name⟩" pill,
  Forget-device menu
- `HarnessDetailView` — slug / status / iteration / last active +
  placeholder card for backend-pending fields

## First build (macOS)

```sh
# 1. Install one-shot tools
brew install xcodegen
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

# 2. Build the Rust core into PapercupCore.xcframework + Swift bindings
cd ..
make build-ios   # runs tools/build-scripts/build-ios.sh

# 3. Generate Papercup.xcodeproj from project.yml
cd ios
xcodegen

# 4. Open + run
open Papercup.xcodeproj
```

## What `build-ios.sh` does

- Cross-compiles `papercup-bindings` (the staticlib that exposes the
  Rust core) for `aarch64-apple-ios`, `aarch64-apple-ios-sim`, and
  `x86_64-apple-ios`
- `lipo`s the two simulator slices into one
- Regenerates Swift bindings into `PapercupCore/`
  (`papercup.swift`, `papercupFFI.h`, `papercupFFI.modulemap`)
- Packages an `xcframework` containing both device + sim slices

## Picking up cold

The contract you need to honour from Swift is in `PapercupCore/papercup.swift`
(generated). Key surface:

```swift
public func version() -> String
public func parseQrPayload(text: String) throws -> QrPayload  // throws PairError
public class OperatorClient {
    public init(baseUrl: String, deviceToken: String?)
    public func listHarnesses() async throws -> [Harness]    // throws ApiError
    public func getHarnessStatus(slug: String) async throws -> HarnessStatus
    public func pair(pairToken: String) async throws -> PairOutcome  // throws PairError
}
public class SyncStream {
    public init(baseUrl: String, deviceToken: String)
    public func nextEvent() async throws -> SyncEvent       // throws SyncError
    public func disconnect()
}
```

If the UDL changes, regenerate via `make bindings-swift` from the
workspace root.

## Known gaps

- No `Assets.xcassets` / app icon — XcodeGen will warn until you add one
- No splash/launch storyboard (relying on `UILaunchScreen_Generation`)
- iOS-side push registration (`/api/mobile/push/register`) and voice
  WSS still pending; both blocked on backend Phase 5
- Mesh / WireGuard not yet ported to iOS — Phase 6

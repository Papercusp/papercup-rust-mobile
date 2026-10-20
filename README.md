# Papercusp Mobile

Native companion apps for a user-controlled Papercusp operator: SwiftUI on
iPhone, Jetpack Compose on Android, with shared Rust behavior through UniFFI.
The retired Tauri/React mobile client is not the implementation.

## Source and runtime

- `crates/papercup-core`: HTTP/device contracts, response models, query polling,
  voice transport and portable recovery behavior.
- `crates/papercup-bindings`: the single UniFFI boundary shared by both native apps.
- `ios`: SwiftUI app, XcodeGen source, XCTest/XCUITest and release metadata.
- `android`: Compose app and Android build/release tooling.
- `tools/build-scripts`: native generation/build, platform preflight and delivery.
- `store`: listing, privacy and reviewer-access material.

The production server is the current TypeScript operator, using `/api/device/*`
under the address supplied by pairing. The Rust core here is a client, not a
replacement server. Do not direct pairing to a retired development server or
hardcode one global operator address.

The five iPhone tabs are Inbox, Operator, Plans, Fleet and Settings. Inbox includes
system alerts and complete attention counts. Fleet uses the existing monitoring
API's current fleets/pots and labels presence as availability rather than running
work. Desktop Settings → Remote access → Pair a phone supplies the QR/link/paste
entry point. Shared operator chat and supported voice modes retain their existing
workspace and consent boundaries.

## Local quality gate

```sh
make build-rust
make check
make test-ios-release
```

`make check` runs the repository's Rust, native-boundary, token and build-script
guards. It does not establish that an iPhone app compiles or passes physical-device
acceptance. See [iPhone build and release](ios/README.md) for current Mac/Xcode,
unit/UI, archive and Apple-delivery procedures.

For Android, install Java, Android SDK/NDK and cargo-ndk as required by the existing
build scripts, then use `make build-android`. Generated language bindings and
native binaries must come from the same UDL/source revision.

## Credentials and distribution

Pairing credentials live in platform secure storage. Provider/APNs/signing/App
Store Connect material is external configuration; do not commit credentials.
Cloud voice requires explicit, persistent and revocable consent. The iPhone app
is an operator companion and does not create a hosted account or sell a subscription.

Managed git-sync owns commits and pushes for this independent repository. Do not
manually commit/push or create a feature worktree. Android verification runs
independently of GitHub Actions through the maintained local native CI service
and timer; see [automatic Android CI](docs/BUILD.md#automatic-android-ci).
The iPhone native runner is `tools/ios-ci.py` on a Mac. Simulator checks require
Xcode 16.3+/SDK 17+; current-SDK archive and signed-release checks require Xcode
26+/SDK 26+. See [native iPhone checks and TestFlight delivery](docs/BUILD.md#native-iphone-checks-and-testflight-delivery).

A successful simulator test or unsigned archive is preparation. Real hardware,
production push, signed export, TestFlight processing and approved public App Store
installation have separate acceptance requirements in
[the submission packet](store/APP-STORE-REVIEW.md). The Google Play packet is
[store/PLAY-STORE-REVIEW.md](store/PLAY-STORE-REVIEW.md); Android build, license
and source-provenance evidence lives in
[android/SOURCE-EVIDENCE.md](android/SOURCE-EVIDENCE.md), not in either packet.

## License

GPL-3.0-or-later. See `LICENSE` and the submission packet's distribution-rights
requirement before public App Store delivery.

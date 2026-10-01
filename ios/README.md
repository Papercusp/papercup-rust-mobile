<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Papercusp iPhone

The iPhone client is a SwiftUI companion to a paired Papercusp operator. Its
portable HTTP, cache and voice contracts live in `crates/papercup-core`, exposed
through a dedicated `PapercupCore` UniFFI module and fresh XCFramework.

The app requires iOS 17 or later. Public App Store candidates must use Apple's
currently accepted SDK; `verify-ios-release.sh --require-current-sdk` enforces
the iOS 26 floor. A simulator build or unsigned archive is not a signed release.

## Current surfaces

- Pair by QR, link or pasted payload from desktop Settings → Remote access →
  Pair a phone; the pairing credential is stored in Keychain.
- Inbox displays work items, attention groups and system-health alerts. The
  header and tab badge use the same complete attention count.
- Operator chat shares the workspace conversation; voice uses desktop-local
  transport or the separately consented ElevenLabs cloud transport.
- Plans exposes the current plan contract and supported authority-checked
  actions.
- Fleet reads current presence-based fleets and pots from
  `/api/device/monitoring`. “Available” does not mean an agent is executing.
  A missing producer tile remains unavailable rather than showing zero.
- Settings manages workspace/device access, voice, diagnostics, legal links
  and cloud-voice consent. The app does not create a hosted account or sell a
  subscription; it is a companion to an operator the user controls.

## Build and verify on macOS

Install Xcode, XcodeGen, SwiftFormat, Rust and the three iOS targets:
`aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios`.

```sh
make build-ios
make test-ios
make test-ios-ui
make test-ios-release
```

`build-ios.sh` regenerates Swift/header bindings, rebuilds all three Rust
slices, combines simulator slices and creates one XCFramework. Never pair
new Swift bindings with an older Rust binary.

`PAPERCUP_IOS_SIM_UDID` selects a specific simulator. Unit and UI tests are
separate. Paired UI/voice flows require a fresh `PAPERCUP_PAIR_PAYLOAD`; without
it those cases are skipped and cannot establish paired-flow acceptance.
`PAPERCUP_MINT_PAIR_PAYLOAD_CMD` can mint a new one-use payload per retry.

`tools/run-ios-template-tests.sh unit|ui|build-only` is the maintained named-Mac
runner. It reads XCTest's execution summary and requires non-zero passing tests,
zero failures and zero skips; result-tree nodes do not count as execution. It
forwards a supplied pair payload to the UI test process. `make
test-ios-template-runner` checks the result guard on any host. A build must be exercised on
a capable Mac/current hosted runner; Linux Rust tests do not prove SwiftUI.

## Current-SDK CI

The private `.github/workflows/ci.yml` runs Rust, generated bindings, design-token
drift and the macOS 26 native matrix. Dispatch a release candidate explicitly:

```sh
gh workflow run ci.yml -R Papercusp/papercup-rust-mobile --ref master
```

Record the run's actual `head_sha`; branch names alone do not identify the
candidate. Managed git-sync commits contain `[skip ci]`, so they need this
explicit candidate dispatch. Normal push/PR triggers cover other source changes.
The native matrix also checks clean-install pairing guidance, requires its UI
smoke to execute without skips, and retains the unsigned archive and toolchain
metadata as private candidate evidence.

To exercise paired navigation and retain the actual paired screens, mint a fresh
one-use payload for a dedicated sanitized operator, inject it as the private
repository's `PAPERCUP_PAIR_PAYLOAD` Actions secret, then dispatch with
`-f paired_ui=true`. Rotate the payload for every attempt and remove the secret
after the run. This case performs pairing, live Inbox fetch, Settings navigation,
Plans/Fleet captures and the existing chat journey; its summary must report one
pass, zero failures and zero skips. The private candidate artifact retains its
xcresult, summary and exported screenshots. Without this input, CI covers the
clean-install case and remains partial evidence for paired-flow acceptance.

## Apple delivery and public acceptance

Use the existing `make release-ios ACTION=preflight|archive|export|validate|upload`
entrypoint. Apple team/signing/provisioning and App Store Connect inputs are
external configuration; provider/signing secrets do not belong in this tree.
Production push additionally requires APNs credentials and push-enabled signing.

See `store/APP-STORE-REVIEW.md` for metadata, screenshots, distribution rights,
sanitized durable reviewer access, signing and submission requirements. Real
production APNs, microphone/Bluetooth/interruption, cellular reconnect and
battery checks require an actual signed iPhone installation. TestFlight availability
and approved public App Store availability are distinct delivery milestones.

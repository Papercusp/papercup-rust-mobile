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
a capable Mac; Linux Rust tests do not prove SwiftUI.

## Native CI and current-SDK candidates

Use `tools/ios-ci.py` on the Mac VM. GitHub Actions is retired for iPhone
builds, tests, signing and upload (release plan D-021). The maintained runner
holds an exclusive native executor lock and records exact source/toolchain
identity, executed tests, screenshots and artifact hashes. See
`docs/BUILD.md` for its admission, retention and signing contracts.

```sh
python3 tools/ios-ci.py --preflight
python3 tools/ios-ci.py --mode simulator --force
python3 tools/ios-ci.py --mode check --preflight
python3 tools/ios-ci.py --mode check --force
```

Simulator mode runs native tests with the available supported simulator SDK.
Check mode additionally requires SDK 26 and validates the unsigned device
archive. A simulator pass cannot satisfy current-SDK archive or signed-release
acceptance. Preflight does not establish a test pass. The launch agent installed
by `--install-launch-agent` checks source changes every 30 minutes, including
managed git-sync commits.

For the maintained paired smoke, supply `--paired-ui --pair-payload-file
/private/fresh-payload.json` using a fresh one-use payload for a dedicated
sanitized operator. Keep the owner-only file outside the repository. Paired
execution is never cached; inspect the retained XCTest summary for non-zero
passes, zero failures and zero skips. Results, screenshots and artifact hashes
live under `~/.local/state/papercusp/ios-ci/attempts/`; `latest.json` records
the verdict. This smoke remains partial evidence for the full paired matrix.

## Apple delivery and public acceptance

Use the existing `make release-ios ACTION=preflight|archive|export|validate|upload`
entrypoint. Apple team/signing/provisioning and App Store Connect inputs are
external configuration; provider/signing secrets do not belong in this tree.
Production push additionally requires APNs credentials and push-enabled signing.

See `store/APP-STORE-REVIEW.md` for metadata, screenshots, distribution rights,
sanitized durable reviewer access, signing and submission requirements. All
device acceptance runs on the Mac VM's iPhone simulator (release plan D-026),
including simulated push routing, injected-audio voice and consent, permission
recovery, background/resume and network loss/reconnect. Record real cellular,
production APNs delivery, Bluetooth hardware and battery endurance as known
simulator limits; these do not require Avi's phone or TestFlight testing.

Manual downloads use a validated signed Ad Hoc IPA for registered devices;
a simulator build or unsigned archive cannot be installed on a phone. See
`docs/BUILD.md` for profile/device requirements. Signing, Apple upload and
approved public App Store availability remain separate delivery milestones.

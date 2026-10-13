<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# iPhone simulator acceptance and late device checks (1.0)

P-008 R-2 runs on the maintained Mac VM iPhone simulator under
iphone-public-release-2026-08-11#D-026. App Store credentials, TestFlight
and a physical iPhone are not prerequisites for these simulator rows.
D-021 retires GitHub Actions; use the native runner in `docs/BUILD.md`.

Record each row as pass, fail or not run with the exact source fingerprint,
Mac/Xcode/simulator versions, time, endpoint and retained result or screenshot.
Keep tokens, pairing codes and personal workspace content out of evidence.
A unit test or backend-free smoke alone does not close a live acceptance row.

## Before you start

- Build and check the exact candidate with
  `python3 tools/ios-ci.py --mode simulator --force`. Its retained `result.json`
  must show completed build, unit and UI phases; preflight is not a test pass.
- Use an explicitly selected simulator and a sanitized current-build operator.
  Delete the earlier app installation for the clean-install row. Preserve the
  selected app and runtime identity throughout the remaining journeys.
- Pair through the visible app choices and the desktop's current
  Settings → Remote access screen. The paired runner's launch-payload hook is
  test plumbing; it does not prove a new user can complete visible onboarding.
- Use owned workspace/device fixtures and supported LAN and public HTTPS routes.
  A simulator HTTPS journey exercises transport without claiming cellular-radio
  behavior. BYOC P-016 requires its own accepted cloud target and custody evidence.

## P-008 simulator rows

| # | Do this | Pass when |
|---|---|---|
| 1 | Open a clean installation | Pair choices appear with no previous pairing; instructions name Settings → Remote access and supported desktop/cloud access |
| 2 | Pair from Remote access using the visible manual-paste flow on LAN | The authorized workspace loads and a chat reply streams in; no developer-only onboarding instruction is needed |
| 3 | Pair and use a supported public HTTPS route | The authorized workspace and chat work through HTTPS without a LAN endpoint; evidence names the route actually used |
| 4 | Relaunch the paired app without reinstalling | Keychain pairing survives and the same authorized workspace opens |
| 5 | Disconnect the owned operator, then restore it | The app reports offline rather than unpaired, retains pairing and reconnects automatically |
| 6 | Revoke the owned phone credential, then re-pair | Heartbeat and authenticated reads reject the revoked credential; the app offers Pair again through current Remote access and the fresh pairing succeeds |
| 7 | Exercise expired pair and device credentials | The expired credentials are rejected, the app explains recovery and a fresh Remote access pairing succeeds |
| 8 | Attempt another workspace and switch using supported UI | Unauthorized data never appears; successful switching requires authorization for the selected workspace |
| 9 | Delete and reinstall the app | Old Keychain pairing is cleared and the pair choices appear again |
| 10 | Exercise each advertised hosted/account/paid mode | Supported entitlement and account behavior matches onboarding and store copy; unsupported modes are not promised |

Retain positive and negative controls against the same owned current-build
operator for revocation, expiry and workspace isolation. Screenshots show the
actual candidate UI; API receipts show the authorization outcome. Mark missing
journeys as not run. Only executed, passing rows establish P-008 acceptance.

## Late P-005 publish and physical-device residue

Record real cellular radio, production APNs delivery/tap, Bluetooth and
battery/endurance as P-005 residue under D-026. Simulator `simctl push` can
exercise notification routing but cannot establish production APNs delivery.
Permission accept/deny and cloud-voice consent can be checked in the simulator;
physical microphone/camera behavior needs the later device check.

Signed distribution and App Store/TestFlight delivery use the separate native
signing/upload route in `docs/BUILD.md`, with the required toolchain, explicit
build number and private Apple inputs. Keep those results separate from unsigned
simulator acceptance. The remaining App Store publish is the late owner step.

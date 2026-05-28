<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Designer brief — Papercup mobile (native Compose Android + native SwiftUI iOS)

## What's being designed

Two native mobile apps, sibling to the GPUI desktop app you've already
been styling. Same product (Papercup), different surfaces:

- Android: Jetpack Compose, Material 3, native chrome
- iOS: SwiftUI, native iOS chrome (NavigationStack, List, etc.)

These are NOT cross-platform abstractions. Each platform should look
right for its OS — Material 3 on Android, Human Interface on iOS — but
share a common visual vocabulary (palette, type scale, motion language)
with the desktop where it makes sense.

## Repo + entrypoints

- Repo: github.com/Papercusp/papercup-rust-mobile (clone via deploy key
  if needed; ask if you don't have access)
- Android sources: `android/app/src/main/kotlin/com/papercuspai/operator/mobile/`
- iOS sources: `ios/Papercup/Sources/Papercup/`
- Existing UI is functional but visually plain: stock Material 3 colors,
  no icon set, no splash, no theme. Treat it as wireframe-fidelity.

## What we ship today (visual inventory)

Both platforms have the same screens (some only on Android so far):

1. **PairScreen / PairView** — QR scan + JSON paste fallback
2. **HarnessListScreen / HarnessListView** — list with status chips,
   live SSE pill, mesh chip, pause toggle
3. **HarnessDetailScreen / HarnessDetailView** — alive/escalated/smoke
   chips, mission cost+tokens, feature counts by status, lastDecision body
4. **SettingsScreen** — identity card + workspaces list + paired devices
   list (Android only; iOS mirror pending)
5. **ActivityScreen** — notifications + actions tabs (Android only;
   iOS mirror pending)

Voice surface is pending and will need its own design pass once the
WS lands.

## Visual language

You've been authoring `papercup-native/crates/papercup-app/src/style.rs`
with web_tokens mirror + motion tokens for the desktop. Mobile inherits
that vocabulary:

- Same palette (deep dark futuristic backdrop, accent + warning +
  success roles)
- Same typography intent (compact, technical, mono for paths/IDs)
- Same motion roles (hover/focus/overlay/route/toast/status)
- BUT: respect platform idioms. Don't fight Material's elevation
  system on Android, don't fight iOS's blur / SF Symbols on iOS

Output the mobile token surface as:

- `android/app/src/main/kotlin/com/papercuspai/operator/mobile/theme/PapercupColors.kt`
  + `Type.kt` + `Shapes.kt`
- `ios/Papercup/Sources/Papercup/Theme.swift`

Roughly mirror style.rs structure so future synchronization is mechanical.

## Deliverables

In rough priority order:

1. **App icons** — both stores need an adaptive icon (Android) + 1024px
   iOS icon. Ship a full icon set in `res/mipmap-*` and
   `ios/Papercup/Resources/Assets.xcassets/AppIcon.appiconset/`
2. **Launch screen** — minimal logo on splash. UILaunchScreen on iOS,
   Android 12+ SplashScreen API
3. **Theme tokens** — Material 3 ColorScheme + Typography for Android,
   SwiftUI Color + Font tokens for iOS
4. **Per-screen visual pass** — apply tokens to PairScreen, HarnessList,
   HarnessDetail, Settings, Activity. Style only — don't change props,
   layout structure, or callbacks
5. **Status chip system** — alive/escalated/smoke/paused/mesh/live
   chips appear in multiple screens. Need a consistent component shape
   per platform (Compose AssistChip variant, SwiftUI Capsule preset)
6. **Voice screen** — design before implementation. Needs idle /
   connecting / listening / speaking / error / userSpoke states. The
   desktop has a working visual we can reuse the language from
7. **Empty / error / loading states** — every list screen has a
   "couldn't load" Card with a monospace error blob. Replace with real
   visual treatment

## Constraints

- GPL-3-or-later. Any imported icons / fonts must be license-compatible
  (no "personal use" Figma assets sneaking in)
- Don't touch component structure, props, or routing — that's the
  mobile-agent's surface. Style values only.
- Match Android Material 3 conventions. Do not fight them.
- Match iOS Human Interface Guidelines. Do not fight them.
- Compose components must work in light + dark mode. Default to dark
  (matches desktop), but light shouldn't crash.
- iOS supports Dynamic Type. Don't hardcode point sizes for text body.

## Coordination

- Read `coord/{mobile,frontend,backend,designer,shared}.jsonl` at turn
  start, append to `coord/designer.jsonl` at turn end. Same protocol as
  desktop work.
- Push branches to origin first (per frontend's prior asks). I detect
  via `git fetch` + `git log origin/<branch>` before committing in
  your area.
- Style-only changes can ship on a `design/mobile-*` branch and merge
  to master via cherry-pick (not PR); the human reviews via diffs.
- Open questions land in `coord/designer.jsonl` as `handoff` to
  `mobile`. Same-day response usually.

## What's out of scope (for now)

- Marketing site, App Store screenshots, press kit
- Web/desktop styling (keep doing that on `papercup-native`)
- Onboarding flow design — we have pair → list, no onboarding screens
- Settings screen forms beyond what already renders

## First task suggestion

Start with the **theme tokens + app icons**. Those unblock everything
else and don't require deep screen-by-screen iteration. App icons in
particular are blocking release.

## Reference

- Existing screen screenshots: ask the mobile-agent to drop fresh ones
  into `docs/screenshots/` (`/tmp/papercup-paired.png` and
  `/tmp/papercup-sim.png` are sitting on the host from the iOS
  validation run; Android we can pull anytime via `adb shell screencap`)
- Tauri-era visual reference: `apps/operator/app/settings/mobile/page.tsx`
  + the legacy docs in `papercup-rust-mobile/docs/legacy/`
- Rust core (so you understand the data shapes the screens render):
  `papercup-rust-mobile/crates/papercup-core/src/types.rs`

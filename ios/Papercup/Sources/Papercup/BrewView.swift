// SPDX-License-Identifier: GPL-3.0-or-later
//
// Brew — the live fleet (mobile-apps-revival D-003). Absorbs the old
// "Running" and "Harnesses" tabs into one place: agents + liveness + plan
// progress (the running snapshot) up front, with the full harness roster a
// segment away. Harness detail + the run-log are reachable by tapping a
// harness (AppRoot pushes HarnessDetailView → RunLogView), exactly as the
// two old tabs did — this view just unifies their entry points.
//
// Labeled "Fleet" (the Brew cup-theme label was reversed by the owner 2026-06-05); on mobile the
// fleet view is where you watch a Pot's brews make progress.

import SwiftUI
import PapercupCore

struct BrewView: View {
    let creds: DeviceCredentials
    let liveTick: Int
    let lastInvalidate: String?
    let onSelectHarness: (String) -> Void

    enum Segment: String, CaseIterable, Identifiable {
        case live = "Live"
        case harnesses = "Harnesses"
        var id: String { rawValue }
    }

    // Selection is user-meaningful view state; on desktop this would be a
    // nuqs param. On the phone there's no URL, so @State is the local
    // equivalent — the agent-driveable surface here is the tab itself.
    @State private var segment: Segment = .live

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $segment) {
                ForEach(Segment.allCases) { seg in
                    Text(seg.rawValue).tag(seg)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            switch segment {
            case .live:
                RunningView(
                    creds: creds,
                    invalidationTick: liveTick,
                    onSelectHarness: onSelectHarness
                )
            case .harnesses:
                HarnessListView(
                    creds: creds,
                    liveTick: liveTick,
                    lastInvalidate: lastInvalidate,
                    onSelect: onSelectHarness
                )
            }
        }
        .background(PapercupTheme.screenGradient.ignoresSafeArea())
    }
}

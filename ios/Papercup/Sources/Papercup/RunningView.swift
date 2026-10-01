// SPDX-License-Identifier: GPL-3.0-or-later
import PapercupCore
import SwiftUI

/// Current workspace presence from /api/device/monitoring. Availability is
/// distinct from running work; retired operator scans are not a fleet signal.
struct RunningView: View {
    let creds: DeviceCredentials
    let invalidationTick: Int
    let onSelectHarness: (String) -> Void

    enum LoadState {
        case loading
        case ready(FleetActivitySummary?)
        case failed(String)
    }

    @State private var state: LoadState = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Fleet activity")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(PapercupTheme.text)
                switch state {
                case .loading:
                    ProgressView("Loading fleet activity…")
                case .failed(let message):
                    statusCard(message)
                case .ready(nil):
                    statusCard("Fleet activity is temporarily unavailable. Pull to refresh.")
                case .ready(let activity?):
                    activityContent(activity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 112)
        }
        .papercupScreenChrome()
        .refreshable { await refetch() }
        .task(id: "\(creds.deviceToken)|\(invalidationTick)") { await refetch() }
    }

    @ViewBuilder
    private func activityContent(_ activity: FleetActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(activity.availableAgents) available agents")
                .font(.headline)
                .foregroundStyle(PapercupTheme.text)
            Text("\(activity.agents) registered in this workspace")
                .font(.caption)
                .foregroundStyle(PapercupTheme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .papercupCardContainer(accent: PapercupTheme.info.opacity(0.10))

        if !activity.fleets.isEmpty {
            Text("Fleets").font(.headline).foregroundStyle(PapercupTheme.text)
            ForEach(activity.fleets, id: \.slug) { fleet in
                VStack(alignment: .leading, spacing: 4) {
                    Text(fleet.slug).font(.headline).foregroundStyle(PapercupTheme.text)
                    Text("\(fleet.availableAgents) available · \(fleet.members) members")
                        .font(.caption).foregroundStyle(PapercupTheme.textMuted)
                    if let leader = fleet.leader {
                        Text("Leader: \(leader)").font(.caption).foregroundStyle(PapercupTheme.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("fleet-activity-\(fleet.slug)")
            }
        }

        if !activity.pots.isEmpty {
            Text("Pots").font(.headline).foregroundStyle(PapercupTheme.text)
            ForEach(activity.pots, id: \.slug) { pot in
                Button { onSelectHarness(pot.slug) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pot.slug).font(.headline).foregroundStyle(PapercupTheme.text)
                        Text("\(pot.availableAgents) available · \(pot.agents) registered")
                            .font(.caption).foregroundStyle(PapercupTheme.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
                }
                .buttonStyle(.plain)
            }
        }

        if activity.agents == 0 {
            statusCard("No agents are registered in this workspace.")
        }
    }

    private func statusCard(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(PapercupTheme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
    }

    @MainActor
    private func refetch() async {
        do {
            state = .ready(try await creds.client().fleetActivity())
        } catch {
            state = .failed(FriendlyError.message(error, doing: "loading fleet activity"))
        }
    }
}

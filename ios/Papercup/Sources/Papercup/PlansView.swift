// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plans tab (mobile-apps-revival D-003): browse a Pot's plans → items,
// with item-level nudge/approve.
//
// This rides `GET /api/device/plans` (+ items) over the PG-canonical
// plans — one of the three new device routes (D-002) being built
// server-side (su-14e1b's lane). That route does not exist yet, so this
// is an honest scaffold: it states what's coming rather than calling a
// 404 endpoint or guessing the wire shape (the green-but-stale trap the
// D-001 contract repair was all about). The client method + real list
// land claim-first when the route's shape is published.

import SwiftUI

struct PlansView: View {
    let creds: DeviceCredentials
    let invalidationTick: Int

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerCard
                    comingSoonCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.bottom, 112)
            }
            .papercupScreenChrome()
            .navigationTitle("Plans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PapercupTheme.inkRaised, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(PapercupTheme.accentStrong)
                    .frame(width: 6, height: 6)
                Text("PLANS")
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(PapercupTheme.accentStrong)
            }
            Text("Browse plans → items, right from your phone")
                .font(.headline.weight(.semibold))
                .foregroundStyle(PapercupTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Soon this tab will list your Pot's plans and drill into their items — with tap-to-nudge and tap-to-approve on each, over the same PG-canonical plans your desktop and terminal see.")
                .font(.subheadline)
                .foregroundStyle(PapercupTheme.text.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .papercupCardContainer(accent: PapercupTheme.accent.opacity(0.12))
    }

    private var comingSoonCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("◷")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(PapercupTheme.info)
            VStack(alignment: .leading, spacing: 4) {
                Text("Wiring up the plans feed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PapercupTheme.text)
                Text("The device plans route is in progress. Until it lands, watch live progress on the Brew tab and act on what needs you in the Inbox.")
                    .font(.caption)
                    .foregroundStyle(PapercupTheme.textMuted)
            }
        }
        .papercupCardContainer(accent: PapercupTheme.info.opacity(0.10))
    }
}

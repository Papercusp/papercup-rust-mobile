// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Operator tab.
///
/// The standalone operator-CARD feed is retired (unify-agent-launches
/// D-005): the scanner's "what should I do next" suggestions now land as
/// work_items in the improvements backlog, and the redesign (mobile-apps-
/// revival D-003) replaces this tab with a real chat thread on the shared
/// operator conversation, with suggestion-cards rendered inline as
/// actionable bubbles.
///
/// That chat rides `GET/POST /api/device/operator-converse` (D-002),
/// which is being built server-side (su-14e1b's lane) and does not exist
/// yet. Until it lands, this is an interim surface: the voice FAB (hosted
/// by AppRoot, persistent on every tab) already feeds the same operator
/// conversation, so the operator is reachable by voice today. This view
/// states that plainly rather than calling the dead card endpoints.
struct OperatorView: View {
    let creds: DeviceCredentials
    let invalidationTick: Int
    let onSelectHarness: (String) -> Void
    @ObservedObject var voice: VoiceManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerCard
                    voiceHintCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.bottom, 112)
            }
            .papercupScreenChrome()
            .navigationTitle("Operator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PapercupTheme.inkRaised, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Operator")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(PapercupTheme.text)
                        Text("Chat coming soon")
                            .font(.caption2)
                            .foregroundStyle(PapercupTheme.textMuted)
                    }
                }
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(PapercupTheme.accentStrong)
                    .frame(width: 6, height: 6)
                Text("OPERATOR CONVERSATION")
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(PapercupTheme.accentStrong)
            }
            Text("The chat thread is on the way")
                .font(.headline.weight(.semibold))
                .foregroundStyle(PapercupTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Soon this tab will be a live chat with your operator — the same conversation your desktop and terminal share — with its suggestions shown inline as tap-to-act bubbles. The old standalone suggestion deck has been retired; operator-surfaced work now flows through your plans and the improvements backlog.")
                .font(.subheadline)
                .foregroundStyle(PapercupTheme.text.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .papercupCardContainer(accent: PapercupTheme.accent.opacity(0.12))
    }

    private var voiceHintCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("◉")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(PapercupTheme.accentStrong)
            VStack(alignment: .leading, spacing: 4) {
                Text("Talk to your operator now")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PapercupTheme.text)
                Text("The voice button (bottom-right, on every tab) opens a live voice session with the same operator. Ask it to pause, scan, check a harness, or anything else.")
                    .font(.caption)
                    .foregroundStyle(PapercupTheme.textMuted)
            }
        }
        .papercupCardContainer(accent: PapercupTheme.info.opacity(0.10))
    }
}

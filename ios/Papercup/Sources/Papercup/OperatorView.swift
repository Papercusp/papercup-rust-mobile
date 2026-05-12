// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct OperatorView: View {
    let creds: DeviceCredentials
    let invalidationTick: Int
    let onSelectHarness: (String) -> Void
    @ObservedObject var voice: VoiceManager

    @State private var cards: [OperatorCard]? = nil
    @State private var pending: Set<String> = []
    @State private var hidden: Set<String> = []
    @State private var error: String? = nil

    private var visibleCards: [OperatorCard] {
        (cards ?? []).filter { !hidden.contains($0.id) }
    }

    private var subtitle: String {
        cards == nil ? "Loading…" : "\(visibleCards.count) pending"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let err = error {
                        errorCard(err)
                    }
                    content
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
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(PapercupTheme.textMuted)
                    }
                }
            }
            .task(id: "\(creds.deviceToken)|\(invalidationTick)") { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if cards == nil {
            loadingCard
        } else if visibleCards.isEmpty {
            emptyStateCard
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(visibleCards.enumerated()), id: \.element.id) { index, card in
                    suggestionCard(card, index: index)
                }
            }
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(PapercupTheme.accent)
            Text("Loading…")
                .font(.callout)
                .foregroundStyle(PapercupTheme.textMuted)
        }
        .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
    }

    private var emptyStateCard: some View {
        Text("No pending suggestions.")
            .font(.callout)
            .foregroundStyle(PapercupTheme.textMuted)
            .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
    }

    private func errorCard(_ message: String) -> some View {
        Text(message)
            .font(.footnote.monospaced())
            .foregroundStyle(PapercupTheme.error)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(PapercupTheme.cardBackground(accent: PapercupTheme.error.opacity(0.16)))
    }

    private func suggestionCard(_ card: OperatorCard, index: Int) -> some View {
        let busy = pending.contains(card.id)
        let title = cardTitle(card)
        let target = trimmed(card.targetHarness)
        let reason = trimmed(card.reason)
        let body = trimmed(card.directiveBody)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(PapercupTheme.accentStrong)
                        .frame(width: 6, height: 6)
                    Text("#\(index + 1) · \(card.action)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PapercupTheme.accentStrong)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(PapercupTheme.accent.opacity(0.12), in: Capsule())
                .overlay(Capsule().stroke(PapercupTheme.accentStrong.opacity(0.28), lineWidth: 1))

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    if let kind = trimmed(card.directiveKind) {
                        PapercupChip(text: kind.uppercased(), role: .muted)
                    }
                    PapercupChip(text: card.status.uppercased(), role: chipRole(for: card.status))
                }
            }

            if let title {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(PapercupTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let target {
                Button { onSelectHarness(target) } label: {
                    Text("→ \(target)")
                        .font(.caption)
                        .foregroundStyle(PapercupTheme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            if let reason {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(PapercupTheme.text.opacity(0.88))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let body {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(body)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(PapercupTheme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
                .padding(10)
                .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(PapercupTheme.stroke.opacity(0.45), lineWidth: 1)
                )
            }

            actionTray(card, busy: busy)
        }
        .papercupCardContainer(accent: cardAccent(card))
    }

    @ViewBuilder
    private func actionTray(_ card: OperatorCard, busy: Bool) -> some View {
        HStack(spacing: 8) {
            if card.action == "send_directive" {
                Button { act(on: card, dispatch: true) } label: {
                    actionButtonLabel(
                        title: busy ? "…" : "Dispatch",
                        fill: LinearGradient(
                            colors: [PapercupTheme.accentStrong.opacity(0.98), PapercupTheme.accent.opacity(0.84)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        foreground: PapercupTheme.ink
                    )
                }
                .buttonStyle(.plain)
                .disabled(busy)

                Button { act(on: card, dispatch: false) } label: {
                    actionButtonLabel(
                        title: "Dismiss",
                        fill: LinearGradient(
                            colors: [Color.white.opacity(0.08), Color.white.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        foreground: PapercupTheme.text
                    )
                }
                .buttonStyle(.plain)
                .disabled(busy)
            } else {
                Button { act(on: card, dispatch: false) } label: {
                    actionButtonLabel(
                        title: busy ? "…" : "Acknowledge",
                        fill: LinearGradient(
                            colors: [PapercupTheme.success.opacity(0.26), PapercupTheme.info.opacity(0.16)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        foreground: PapercupTheme.text
                    )
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(PapercupTheme.success.opacity(0.12), lineWidth: 1)
        )
    }

    private func actionButtonLabel(title: String, fill: LinearGradient, foreground: Color) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(PapercupTheme.stroke.opacity(0.65), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 5)
    }

    private func act(on card: OperatorCard, dispatch: Bool) {
        let cardId = card.id
        guard !pending.contains(cardId) else { return }

        error = nil
        pending.insert(cardId)
        hidden.insert(cardId)

        Task {
            let client = creds.client()
            do {
                if dispatch {
                    _ = try await client.dispatchOperatorCard(cardId: cardId)
                } else {
                    _ = try await client.dismissOperatorCard(cardId: cardId)
                }

                do {
                    cards = try await client.listOperatorCards()
                } catch {
                    self.error = "refresh failed: \(error)"
                }
            } catch {
                self.error = dispatch ? "dispatch failed: \(error)" : "dismiss failed: \(error)"
                hidden.remove(cardId)
            }

            pending.remove(cardId)
        }
    }

    private func load() async {
        do {
            cards = try await creds.client().listOperatorCards()
            error = nil
        } catch {
            self.error = "suggestions: \(error)"
            if cards == nil {
                cards = []
            }
        }
    }

    private func trimmed(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private func cardTitle(_ card: OperatorCard) -> String? {
        trimmed(card.directiveSubject) ?? trimmed(card.reason) ?? trimmed(card.targetHarness) ?? trimmed(card.action)
    }

    private func chipRole(for status: String) -> PapercupChipRole {
        switch status.lowercased() {
        case "pending", "queued", "waiting": return .warning
        case "failed", "error": return .error
        case "dispatched", "done", "approved": return .success
        default: return .muted
        }
    }

    private func cardAccent(_ card: OperatorCard) -> Color {
        switch card.action {
        case "send_directive":
            return PapercupTheme.accent.opacity(0.12)
        default:
            return PapercupTheme.info.opacity(0.10)
        }
    }
}

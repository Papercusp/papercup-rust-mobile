// SPDX-License-Identifier: GPL-3.0-or-later
//
// Operator tab — a real chat thread on the SHARED operator conversation
// (mobile-apps-revival D-003, over the D-002 operator-converse routes).
// The same workspace-scoped thread the desktop + TUI use: a turn typed
// here shows up there and vice-versa.
//
// Sending renders the submitted turn IMMEDIATELY (optimistic append),
// then drains the converse SSE server-side (the route persists both
// turns) and re-reads the conversation — so the rendered thread always
// converges on the persisted truth without the user's own message ever
// looking lost while a slow brain drains (WI-4984: under provider
// exhaustion the SSE can take minutes; the persisted user turn must not
// wait on it). An early re-read ~1.5s after submit swaps the optimistic
// bubble for the persisted row as soon as the server has it. The voice
// FAB (hosted by AppRoot) feeds this same conversation by voice.

import SwiftUI
import PapercupCore

struct OperatorView: View {
    let creds: DeviceCredentials
    let invalidationTick: Int
    let onSelectHarness: (String) -> Void
    @ObservedObject var voice: VoiceManager

    enum LoadState {
        case loading
        case ready(ConversationRead)
        case failed(String)
    }

    @State private var state: LoadState = .loading
    @State private var draft: String = ""
    @State private var sending = false
    @State private var sendError: String? = nil
    /// Optimistically appended user turns, rendered until the persisted
    /// read covers them (WI-4984). At most one is live at a time because
    /// `sending` serializes sends.
    @State private var pendingTurns: [OperatorTurn] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            switch state {
                            case .loading:
                                loadingCard
                            case .failed(let msg):
                                errorCard(msg)
                            case .ready(let read):
                                if read.hasMoreEarlier {
                                    Text("Earlier turns on your desktop")
                                        .font(.caption2)
                                        .foregroundStyle(PapercupTheme.textMuted)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }
                                if read.turns.isEmpty {
                                    emptyCard
                                }
                                ForEach(read.turns, id: \.id) { turn in
                                    turnBubble(turn).id(turn.id)
                                }
                            }
                            ForEach(visiblePendingTurns, id: \.id) { turn in
                                turnBubble(turn).id(turn.id)
                            }
                            if sending {
                                thinkingBubble.id("thinking")
                            }
                            if let err = sendError {
                                Text(err)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(PapercupTheme.error)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .padding(.bottom, 96)
                    }
                    .onChange(of: lastTurnId) { _, new in
                        if let id = new {
                            withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                        }
                    }
                    .onChange(of: sending) { _, isSending in
                        if isSending {
                            withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                        }
                    }
                }
                inputBar
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
                        Text("Shared with desktop")
                            .font(.caption2)
                            .foregroundStyle(PapercupTheme.textMuted)
                    }
                }
            }
            .task(id: "\(creds.deviceToken)|\(invalidationTick)") { await load() }
        }
    }

    private var lastTurnId: String? {
        if let pendingId = visiblePendingTurns.last?.id { return pendingId }
        if case .ready(let read) = state { return read.turns.last?.id }
        return nil
    }

    /// Pending turns not yet visible in the persisted read (WI-4984).
    private var visiblePendingTurns: [OperatorTurn] {
        guard case .ready(let read) = state else { return pendingTurns }
        return pendingTurns.filter { !PendingTurnCoverage.isCovered(by: read.turns, pending: $0) }
    }

    // MARK: - bubbles

    @ViewBuilder
    private func turnBubble(_ turn: OperatorTurn) -> some View {
        let isUser = turn.role == "user"
        let isSystem = turn.role == "system"
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(turn.text)
                    .font(isSystem ? .caption : .subheadline)
                    .foregroundStyle(isSystem ? PapercupTheme.textMuted : PapercupTheme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if turn.source.hasPrefix("voice") {
                        Text("◉ voice")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(PapercupTheme.accentStrong.opacity(0.7))
                    }
                    if turn.toolsJson != "null", !turn.toolsJson.isEmpty {
                        Text("⚙ action card")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(PapercupTheme.info.opacity(0.8))
                    }
                    Text(Self.timeLabel(ms: turn.createdAt))
                        .font(.system(size: 9))
                        .foregroundStyle(PapercupTheme.textMuted.opacity(0.7))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                isUser
                    ? PapercupTheme.accent.opacity(0.16)
                    : PapercupTheme.inkRaised.opacity(0.92),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        (isUser ? PapercupTheme.accentStrong : PapercupTheme.stroke).opacity(0.30),
                        lineWidth: 1
                    )
            )
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var thinkingBubble: some View {
        HStack {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini).tint(PapercupTheme.accent)
                Text("Operator is working…")
                    .font(.caption)
                    .foregroundStyle(PapercupTheme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(PapercupTheme.inkRaised.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer(minLength: 40)
        }
    }

    private var emptyCard: some View {
        Text("Say hello — this is the same conversation your desktop operator sees.")
            .font(.callout)
            .foregroundStyle(PapercupTheme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .papercupCardContainer(accent: PapercupTheme.info.opacity(0.08))
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(PapercupTheme.accent)
            Text("Loading conversation…").font(.callout).foregroundStyle(PapercupTheme.textMuted)
        }
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

    // MARK: - input

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Message the operator…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .font(.subheadline)
                .foregroundStyle(PapercupTheme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(PapercupTheme.inkRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .disabled(sending)
            Button {
                send()
            } label: {
                Text(sending ? "…" : "Send")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(canSend ? PapercupTheme.ink : PapercupTheme.textMuted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(
                        canSend ? PapercupTheme.accent : PapercupTheme.inkRaised,
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(PapercupTheme.ink.opacity(0.96))
    }

    private var canSend: Bool {
        !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - data

    private func load() async {
        do {
            let read = try await creds.client().operatorConversation(limit: 50)
            state = .ready(read)
            // The persisted read now carries these turns — drop the
            // optimistic copies so nothing renders twice (WI-4984).
            pendingTurns.removeAll { PendingTurnCoverage.isCovered(by: read.turns, pending: $0) }
        } catch {
            if case .loading = state {
                state = .failed(FriendlyError.message(error, doing: "loading the conversation"))
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        draft = ""
        sending = true
        sendError = nil
        // WI-4984: render the submitted turn IMMEDIATELY. The converse
        // SSE below can take minutes under a slow brain; the user's own
        // message must never look lost while it drains.
        let pending = OperatorTurn(
            id: "pending-\(UUID().uuidString)",
            seq: .max,
            role: "user",
            text: text,
            source: "text",
            createdAt: Int64(Date().timeIntervalSince1970 * 1000),
            toolsJson: "null"
        )
        pendingTurns.append(pending)
        Task {
            defer { sending = false }
            // Early re-read: the route persists the user turn at
            // submission, so a refresh shortly after send swaps the
            // optimistic bubble for the persisted row without waiting
            // on the assistant.
            let earlyRefresh = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !Task.isCancelled { await load() }
            }
            // UI-test hook (WI-4984 regression): a launch-injected delay
            // simulates a slow brain so XCUITest can assert the submitted
            // turn renders BEFORE the converse drain completes. Absent in
            // production (env unset ⇒ no-op).
            if let raw = ProcessInfo.processInfo.environment["PAPERCUP_UITEST_CONVERSE_DELAY_MS"],
               let delayMs = UInt64(raw), delayMs > 0 {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
            do {
                // Drains the converse SSE — returns once the operator's
                // turn is persisted — then re-read to render both turns.
                try await creds.client().operatorConverse(text: text)
            } catch {
                sendError = FriendlyError.message(error, doing: "sending your message")
            }
            earlyRefresh.cancel()
            await load()
            // The persisted read is now truth. A still-uncovered pending
            // turn means the send genuinely failed: drop the bubble (the
            // error is showing) and hand the text back to retry.
            if pendingTurns.contains(where: { $0.id == pending.id }) {
                pendingTurns.removeAll { $0.id == pending.id }
                if sendError != nil, draft.isEmpty {
                    draft = text
                }
            }
        }
    }

    private static func timeLabel(ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }
}

/// WI-4984: decides when a persisted conversation read covers an
/// optimistically rendered user turn (same author-role + text, persisted
/// at-or-after the optimistic submission, with slack for device↔server
/// clock skew). Internal — unit-tested in PendingTurnCoverageTests.
enum PendingTurnCoverage {
    /// Clock-skew slack between the device timestamp stamped on the
    /// optimistic turn and the server timestamp on the persisted row.
    static let clockSkewSlackMs: Int64 = 120_000

    static func isCovered(by persisted: [OperatorTurn], pending: OperatorTurn) -> Bool {
        persisted.contains { turn in
            turn.role == "user"
                && turn.text == pending.text
                && turn.createdAt >= pending.createdAt - clockSkewSlackMs
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import PapercupCore
import UIKit

/// Banner that surfaces a Failed voice state with a kind-specific
/// action. Mirrors Android's VoiceErrorBanner — same UX matrix:
///   - micPermission     → Open Settings
///   - quotaExceeded     → Dismiss (Voice Settings already shows usage)
///   - concurrentLimit   → Pre-empt
///   - mintCooldown      → countdown — no manual action
///   - networkUnreachable→ Retry
///   - idleTimeout       → Resume
///   - sessionMax        → Resume
///   - agentEnded        → auto-dismiss after 2s
///   - unknown           → Retry + Dismiss
struct VoiceErrorBanner: View {
    @ObservedObject var voice: VoiceManager
    @State private var countdown: Int = 0
    @State private var countdownTask: Task<Void, Never>?

    var body: some View {
        if case .failed(let message, let kind, let retryAfterSec) = voice.state {
            HStack(alignment: .center, spacing: 8) {
                Text(displayMessage(message: message, kind: kind, retryAfterSec: retryAfterSec))
                    .font(.caption)
                    .foregroundStyle(PapercupTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actionButtons(kind: kind, retryAfterSec: retryAfterSec)
                Button("×") { voice.stop() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(PapercupTheme.text)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(accent(kind: kind))
            .task(id: kind) { await wireAutoBehavior(kind: kind, retryAfterSec: retryAfterSec) }
        }
    }

    @ViewBuilder
    private func actionButtons(kind: VoiceManager.FailureKind, retryAfterSec: Int?) -> some View {
        switch kind {
        case .micPermission:
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderless)
        case .quotaExceeded:
            Button("Dismiss") { voice.stop() }
                .buttonStyle(.borderless)
        case .concurrentLimit:
            Button("Pre-empt") { voice.start() }
                .buttonStyle(.borderless)
        case .mintCooldown:
            if countdown <= 0 {
                Button("Retry") { voice.start() }
                    .buttonStyle(.borderless)
            } else {
                Button("Cancel") { voice.stop() }
                    .buttonStyle(.borderless)
            }
        case .networkUnreachable, .unknown:
            Button("Retry") { voice.start() }
                .buttonStyle(.borderless)
        case .idleTimeout, .sessionMax:
            Button("Resume") { voice.start() }
                .buttonStyle(.borderless)
        case .agentEnded:
            EmptyView()
        }
    }

    private func displayMessage(message: String, kind: VoiceManager.FailureKind, retryAfterSec: Int?) -> String {
        switch kind {
        case .mintCooldown:
            return countdown > 0
                ? "Cooling down — retry in \(countdown)s."
                : "Cooldown cleared — tap to retry."
        default:
            return message
        }
    }

    private func accent(kind: VoiceManager.FailureKind) -> Color {
        switch kind {
        case .agentEnded, .idleTimeout, .sessionMax, .mintCooldown:
            return PapercupTheme.accent.opacity(0.18)
        default:
            return Color.red.opacity(0.22)
        }
    }

    @MainActor
    private func wireAutoBehavior(kind: VoiceManager.FailureKind, retryAfterSec: Int?) async {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = 0
        if kind == .agentEnded {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            // Only dismiss if we're still in the same failed state.
            if case .failed(_, .agentEnded, _) = voice.state { voice.stop() }
            return
        }
        if kind == .mintCooldown, let secs = retryAfterSec, secs > 0 {
            countdown = secs
            countdownTask = Task { @MainActor in
                while countdown > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                    countdown -= 1
                }
            }
        }
    }
}

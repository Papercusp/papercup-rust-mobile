// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

enum PapercupTheme {
    static let ink = Color(red: 0.02, green: 0.03, blue: 0.07)
    static let inkRaised = Color(red: 0.04, green: 0.07, blue: 0.12)
    static let surface = Color(red: 0.06, green: 0.10, blue: 0.16)
    static let stroke = Color(red: 0.14, green: 0.20, blue: 0.27)
    static let text = Color(red: 0.90, green: 0.95, blue: 1.00)
    static let textMuted = Color(red: 0.56, green: 0.64, blue: 0.72)
    static let accent = Color(red: 0.13, green: 0.83, blue: 0.93)
    static let accentStrong = Color(red: 0.40, green: 0.91, blue: 0.98)
    static let success = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let warning = Color(red: 0.98, green: 0.75, blue: 0.14)
    static let error = Color(red: 0.98, green: 0.44, blue: 0.52)
    static let info = Color(red: 0.38, green: 0.65, blue: 0.98)

    static let screenGradient = LinearGradient(
        colors: [Color(red: 0.03, green: 0.07, blue: 0.11), ink, Color.black],
        startPoint: .top,
        endPoint: .bottom
    )

    static let cardCornerRadius: CGFloat = 20

    static func cardBackground(accent accentColor: Color = PapercupTheme.accent.opacity(0.12)) -> some View {
        let shape = RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
        return shape
            .fill(surface.opacity(0.92))
            .overlay(shape.fill(accentColor))
            .overlay(shape.stroke(stroke.opacity(0.72), lineWidth: 1))
    }
}

enum PapercupChipRole {
    case accent
    case success
    case warning
    case error
    case info
    case muted

    var foreground: Color {
        switch self {
        case .accent: return PapercupTheme.accentStrong
        case .success: return PapercupTheme.success
        case .warning: return PapercupTheme.warning
        case .error: return PapercupTheme.error
        case .info: return PapercupTheme.info
        case .muted: return PapercupTheme.textMuted
        }
    }

    var background: Color { foreground.opacity(self == .muted ? 0.12 : 0.18) }
}

struct PapercupChip: View {
    let text: String
    var role: PapercupChipRole = .accent

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(role.foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(role.background, in: Capsule())
            .overlay(Capsule().stroke(role.foreground.opacity(0.45), lineWidth: 1))
    }
}

struct PapercupSectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(PapercupTheme.textMuted)
            .tracking(0.8)
    }
}

extension View {
    func papercupScreenChrome() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(PapercupTheme.screenGradient.ignoresSafeArea())
            .tint(PapercupTheme.accent)
    }

    func papercupCardRow(accent: Color = PapercupTheme.accent.opacity(0.10)) -> some View {
        self
            .listRowBackground(PapercupTheme.cardBackground(accent: accent))
            .listRowSeparator(.hidden)
    }

    func papercupMonoMeta() -> some View {
        self
            .font(.caption.monospaced())
            .foregroundStyle(PapercupTheme.textMuted)
    }
}

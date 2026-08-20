// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import PapercupCore

// Thin override layer over PapercupTokens (generated from design-tokens/tokens.json).
// Keep this enum for: gradients, shapes, platform-specific tweaks. Single-color tokens
// live in PapercupTokens and should not be redefined here.
enum PapercupTheme {
    static let ink = PapercupTokens.ink
    static let inkRaised = PapercupTokens.inkRaised
    static let surface = PapercupTokens.surface
    static let stroke = PapercupTokens.stroke
    static let text = PapercupTokens.text
    static let textMuted = PapercupTokens.textMuted
    static let accent = PapercupTokens.accent
    static let accentStrong = PapercupTokens.accentStrong
    static let operatorHeroCyan = PapercupTokens.operatorHeroCyan
    static let success = PapercupTokens.success
    static let warning = PapercupTokens.warning
    static let error = PapercupTokens.error
    static let info = PapercupTokens.info

    static let screenGradient = LinearGradient(
        colors: [
            Color(.sRGB, red: 0.0392, green: 0.1294, blue: 0.2157, opacity: 1),
            Color(.sRGB, red: 0.0275, green: 0.0667, blue: 0.1137, opacity: 1),
            ink,
            Color(.sRGB, red: 0.0078, green: 0.0157, blue: 0.0353, opacity: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let cardCornerRadius: CGFloat = 20

    static func cardBackground(accent accentColor: Color = PapercupTheme.accent.opacity(0.12)) -> some View {
        let shape = RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
        return ZStack {
            shape.fill(surface.opacity(0.92))
            shape.fill(
                LinearGradient(
                    colors: [
                        accentStrong.opacity(0.12),
                        accentColor.opacity(0.72),
                        warning.opacity(0.035),
                        success.opacity(0.045),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            PapercupTopCornerRails()
                .stroke(accentStrong.opacity(0.38), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .clipShape(shape)
            PapercupBottomCornerRails()
                .stroke(warning.opacity(0.30), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .clipShape(shape)
            PapercupCornerRivets(radius: 7, inset: 16)
                .fill(warning.opacity(0.16))
                .clipShape(shape)
            PapercupCornerRivets(radius: 1.6, inset: 16)
                .fill(accentStrong.opacity(0.92))
                .clipShape(shape)
            shape.stroke(stroke.opacity(0.72), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.28), radius: 14, x: 0, y: 10)
    }
}

private struct PapercupTopCornerRails: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: min(84, rect.width * 0.45), y: 0))
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 0, y: min(72, rect.height * 0.45)))
        path.move(to: CGPoint(x: max(0, rect.width - 104), y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.move(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: min(72, rect.height * 0.45)))
        return path
    }
}

private struct PapercupBottomCornerRails: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let railHeight = min(72, rect.height * 0.45)
        path.move(to: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: min(84, rect.width * 0.45), y: rect.height))
        path.move(to: CGPoint(x: 0, y: rect.height - railHeight))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.move(to: CGPoint(x: max(0, rect.width - 104), y: rect.height))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.move(to: CGPoint(x: rect.width, y: rect.height - railHeight))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        return path
    }
}

private struct PapercupCornerRivets: Shape {
    let radius: CGFloat
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        [
            CGPoint(x: inset, y: inset),
            CGPoint(x: rect.width - inset, y: inset),
            CGPoint(x: inset, y: rect.height - inset),
            CGPoint(x: rect.width - inset, y: rect.height - inset),
        ].forEach { point in
            path.addEllipse(in: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
        return path
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

    @State private var pulse = false

    private var pulses: Bool {
        let normalized = text.replacingOccurrences(of: "_", with: " ").lowercased()
        return normalized.contains("progress")
            || normalized.contains("validating")
            || normalized.contains("running")
            || normalized.contains("pairing")
            || normalized.contains("scanning")
            || normalized == "live"
    }

    var body: some View {
        HStack(spacing: 5) {
            if pulses {
                Circle()
                    .fill(role.foreground.opacity(pulse ? 1 : 0.42))
                    .frame(width: 6, height: 6)
            }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(role.foreground)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(role.background, in: Capsule())
        .overlay(Capsule().stroke(role.foreground.opacity(0.45), lineWidth: 1))
        .onAppear {
            guard pulses else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
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

    func papercupCardContainer(accent: Color = PapercupTheme.accent.opacity(0.12)) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(PapercupTheme.cardBackground(accent: accent))
    }

    func papercupMonoMeta() -> some View {
        self
            .font(.caption.monospaced())
            .foregroundStyle(PapercupTheme.textMuted)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// AUTO-GENERATED from design-tokens/*.tokens.json. Do not edit.
// Run: pnpm tokens (or npm run tokens)
import SwiftUI

enum PapercupTokens {
    static let primaryButtonText = Color(.sRGB, red: 0.0118, green: 0.0902, blue: 0.0706, opacity: 1.0000)
    /// Mobile-specific pale cyan for the pair button gradient top — distinct from desktop's sky-cool (#D7F3FF) which serves a different role
    static let primaryButtonGradTop = Color(.sRGB, red: 0.8275, green: 0.9804, blue: 1.0000, opacity: 1.0000)
    static let primaryButtonGradBottom = Color(.sRGB, red: 0.0118, green: 0.4118, blue: 0.6314, opacity: 1.0000)
    static let shadeRaised = Color(.sRGB, red: 0.0314, green: 0.0784, blue: 0.1294, opacity: 1.0000)
    static let shadeSurface = Color(.sRGB, red: 0.0314, green: 0.0784, blue: 0.1294, opacity: 1.0000)
    static let shadePopover = Color(.sRGB, red: 0.0431, green: 0.0941, blue: 0.1529, opacity: 1.0000)
    static let shadeDeep = Color(.sRGB, red: 0.0157, green: 0.0314, blue: 0.0588, opacity: 1.0000)
    static let shadeButton = Color(.sRGB, red: 0.0118, green: 0.0667, blue: 0.0941, opacity: 1.0000)
    static let shadeBtnText = Color(.sRGB, red: 0.0118, green: 0.0902, blue: 0.0706, opacity: 1.0000)
    static let whiteTint = Color(.sRGB, red: 0.9529, green: 0.9843, blue: 1.0000, opacity: 1.0000)
    static let ink = Color(.sRGB, red: 0.0157, green: 0.0314, blue: 0.0588, opacity: 1.0000)
    static let inkRaised = Color(.sRGB, red: 0.0314, green: 0.0784, blue: 0.1294, opacity: 1.0000)
    static let surface = Color(.sRGB, red: 0.0314, green: 0.0784, blue: 0.1294, opacity: 1.0000)
    static let surfaceStrong = Color(.sRGB, red: 0.0431, green: 0.0941, blue: 0.1529, opacity: 1.0000)
    static let popover = Color(.sRGB, red: 0.0431, green: 0.0941, blue: 0.1529, opacity: 1.0000)
    /// Color(.sRGB, red: 0.4902, green: 0.8275, blue: 0.9882, opacity: 1.0000) @ 0.22
    static let stroke = Color(.sRGB, red: 0.4902, green: 0.8275, blue: 0.9882, opacity: 0.2196)
    /// Color(.sRGB, red: 0.4902, green: 0.8275, blue: 0.9882, opacity: 1.0000) @ 0.34
    static let strokeStrong = Color(.sRGB, red: 0.4902, green: 0.8275, blue: 0.9882, opacity: 0.3412)
    /// Color(.sRGB, red: 0.4902, green: 0.8275, blue: 0.9882, opacity: 1.0000) @ 0.12
    static let strokeSoft = Color(.sRGB, red: 0.4902, green: 0.8275, blue: 0.9882, opacity: 0.1216)
    static let text = Color(.sRGB, red: 0.9529, green: 0.9843, blue: 1.0000, opacity: 1.0000)
    /// Color(.sRGB, red: 0.7961, green: 0.8353, blue: 0.8824, opacity: 1.0000) @ 0.74
    static let textMuted = Color(.sRGB, red: 0.7961, green: 0.8353, blue: 0.8824, opacity: 0.7412)
    /// Color(.sRGB, red: 0.5804, green: 0.6392, blue: 0.7216, opacity: 1.0000) @ 0.68
    static let textFaint = Color(.sRGB, red: 0.5804, green: 0.6392, blue: 0.7216, opacity: 0.6784)
    static let accent = Color(.sRGB, red: 0.2196, green: 0.7412, blue: 0.9725, opacity: 1.0000)
    static let accentStrong = Color(.sRGB, red: 0.4902, green: 0.8275, blue: 0.9882, opacity: 1.0000)
    static let accentCool = Color(.sRGB, red: 0.7294, green: 0.9020, blue: 0.9922, opacity: 1.0000)
    /// Color(.sRGB, red: 0.2196, green: 0.7412, blue: 0.9725, opacity: 1.0000) @ 0.14
    static let accentSoft = Color(.sRGB, red: 0.2196, green: 0.7412, blue: 0.9725, opacity: 0.1412)
    static let operatorHeroCyan = Color(.sRGB, red: 0.0745, green: 0.9608, blue: 1.0000, opacity: 1.0000)
    static let teal = Color(.sRGB, red: 0.2039, green: 0.8275, blue: 0.6000, opacity: 1.0000)
    /// Color(.sRGB, red: 0.2039, green: 0.8275, blue: 0.6000, opacity: 1.0000) @ 0.14
    static let tealSoft = Color(.sRGB, red: 0.2039, green: 0.8275, blue: 0.6000, opacity: 0.1412)
    /// Color(.sRGB, red: 0.9647, green: 0.7686, blue: 0.3255, opacity: 1.0000) @ 0.14
    static let goldSoft = Color(.sRGB, red: 0.9647, green: 0.7686, blue: 0.3255, opacity: 0.1412)
    static let buttonInk = Color(.sRGB, red: 0.0118, green: 0.0667, blue: 0.0941, opacity: 1.0000)
    static let success = Color(.sRGB, red: 0.2039, green: 0.8275, blue: 0.6000, opacity: 1.0000)
    /// Color(.sRGB, red: 0.2039, green: 0.8275, blue: 0.6000, opacity: 1.0000) @ 0.19
    static let successSoft = Color(.sRGB, red: 0.2039, green: 0.8275, blue: 0.6000, opacity: 0.1882)
    /// Mobile uses gold-400 (Papercusp custom) where desktop uses amber-400 (Tailwind) — intentional divergence
    static let warning = Color(.sRGB, red: 0.9647, green: 0.7686, blue: 0.3255, opacity: 1.0000)
    /// Color(.sRGB, red: 0.9647, green: 0.7686, blue: 0.3255, opacity: 1.0000) @ 0.20
    static let warningSoft = Color(.sRGB, red: 0.9647, green: 0.7686, blue: 0.3255, opacity: 0.2000)
    static let error = Color(.sRGB, red: 0.9843, green: 0.4431, blue: 0.5216, opacity: 1.0000)
    /// Color(.sRGB, red: 0.9843, green: 0.4431, blue: 0.5216, opacity: 1.0000) @ 0.20
    static let errorSoft = Color(.sRGB, red: 0.9843, green: 0.4431, blue: 0.5216, opacity: 0.2000)
    static let info = Color(.sRGB, red: 0.4902, green: 0.8275, blue: 0.9882, opacity: 1.0000)
    /// Color(.sRGB, red: 0.4902, green: 0.8275, blue: 0.9882, opacity: 1.0000) @ 0.18
    static let infoSoft = Color(.sRGB, red: 0.4902, green: 0.8275, blue: 0.9882, opacity: 0.1804)
    static let sky100 = Color(.sRGB, red: 0.8784, green: 0.9490, blue: 0.9961, opacity: 1.0000)
    static let sky200 = Color(.sRGB, red: 0.7294, green: 0.9020, blue: 0.9922, opacity: 1.0000)
    static let sky300 = Color(.sRGB, red: 0.4902, green: 0.8275, blue: 0.9882, opacity: 1.0000)
    static let sky400 = Color(.sRGB, red: 0.2196, green: 0.7412, blue: 0.9725, opacity: 1.0000)
    static let sky500 = Color(.sRGB, red: 0.0549, green: 0.6471, blue: 0.9137, opacity: 1.0000)
    static let sky700 = Color(.sRGB, red: 0.0118, green: 0.4118, blue: 0.6314, opacity: 1.0000)
    /// Desktop accent-cool — between sky-100 and sky-200
    static let skyCool = Color(.sRGB, red: 0.8431, green: 0.9529, blue: 1.0000, opacity: 1.0000)
    /// Operator hero cyan — orb chrome
    static let skyHero = Color(.sRGB, red: 0.0745, green: 0.9608, blue: 1.0000, opacity: 1.0000)
    static let emerald400 = Color(.sRGB, red: 0.2039, green: 0.8275, blue: 0.6000, opacity: 1.0000)
    /// Tailwind amber-400 — desktop --warn
    static let amber400 = Color(.sRGB, red: 0.9843, green: 0.7490, blue: 0.1412, opacity: 1.0000)
    /// Papercusp custom yellow — mobile uses this instead of amber-400 for warmer feel
    static let gold400 = Color(.sRGB, red: 0.9647, green: 0.7686, blue: 0.3255, opacity: 1.0000)
    static let rose400 = Color(.sRGB, red: 0.9843, green: 0.4431, blue: 0.5216, opacity: 1.0000)
    static let slate300 = Color(.sRGB, red: 0.7961, green: 0.8353, blue: 0.8824, opacity: 1.0000)
    static let slate400 = Color(.sRGB, red: 0.5804, green: 0.6392, blue: 0.7216, opacity: 1.0000)
}

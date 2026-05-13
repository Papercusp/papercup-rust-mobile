// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile.theme

import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

// Thin override layer over PapercupTokens (generated from design-tokens/tokens.json).
// Keep this file for: gradients/brushes, platform-specific tweaks, and any color
// that should diverge from cross-platform spec. Single-color tokens live in PapercupTokens.
object PapercupColors {
    val Ink = PapercupTokens.Ink
    val InkRaised = PapercupTokens.InkRaised
    val Surface = PapercupTokens.Surface
    val SurfaceStrong = PapercupTokens.SurfaceStrong
    val Popover = PapercupTokens.Popover
    val Stroke = PapercupTokens.Stroke
    val StrokeStrong = PapercupTokens.StrokeStrong
    val StrokeSoft = PapercupTokens.StrokeSoft
    val Text = PapercupTokens.Text
    val TextMuted = PapercupTokens.TextMuted
    val TextFaint = PapercupTokens.TextFaint
    val Accent = PapercupTokens.Accent
    val AccentStrong = PapercupTokens.AccentStrong
    val AccentCool = PapercupTokens.AccentCool
    val OperatorHeroCyan = PapercupTokens.OperatorHeroCyan
    val AccentSoft = PapercupTokens.AccentSoft
    val Teal = PapercupTokens.Teal
    val TealSoft = PapercupTokens.TealSoft
    val Gold = PapercupTokens.Gold
    val GoldSoft = PapercupTokens.GoldSoft
    val ButtonInk = PapercupTokens.ButtonInk
    val Success = PapercupTokens.Success
    val SuccessSoft = PapercupTokens.SuccessSoft
    val Warning = PapercupTokens.Warning
    val WarningSoft = PapercupTokens.WarningSoft
    val Error = PapercupTokens.Error
    val ErrorSoft = PapercupTokens.ErrorSoft
    val Info = PapercupTokens.Info
    val InfoSoft = PapercupTokens.InfoSoft

    val ScreenGradient = Brush.verticalGradient(
        listOf(
            Color(0xFF0A2137),
            Color(0xFF07111D),
            Ink,
            Color(0xFF020409),
        ),
    )

    val HeaderGradient = Brush.verticalGradient(
        listOf(
            SurfaceStrong.copy(alpha = 0.96f),
            Color(0xF0050C16),
        ),
    )

    val CardGradient = Brush.linearGradient(
        listOf(
            Color(0x217DD3FC),
            Color(0x0BF6C453),
            Color(0x0F34D399),
        ),
    )

    val PanelGradient = Brush.verticalGradient(
        listOf(
            Color(0x14FFFFFF),
            Color(0x05000000),
        ),
    )

    val PrimaryButtonGradient = Brush.verticalGradient(
        listOf(
            PapercupTokens.PrimaryButtonGradTop,
            PapercupTokens.Accent,
            PapercupTokens.PrimaryButtonGradBottom,
        ),
    )
}

val PapercupDarkColorScheme = darkColorScheme(
    primary = PapercupColors.Accent,
    onPrimary = Color(0xFF001F28),
    primaryContainer = Color(0xFF083A45),
    onPrimaryContainer = PapercupColors.AccentStrong,
    secondary = PapercupColors.Success,
    onSecondary = Color(0xFF032318),
    secondaryContainer = Color(0xFF12392D),
    onSecondaryContainer = Color(0xFFA7F3D0),
    tertiary = PapercupColors.Gold,
    onTertiary = Color(0xFF1E1500),
    tertiaryContainer = Color(0xFF40300A),
    onTertiaryContainer = PapercupColors.GoldSoft,
    background = PapercupColors.Ink,
    onBackground = PapercupColors.Text,
    surface = PapercupColors.Surface,
    onSurface = PapercupColors.Text,
    surfaceVariant = PapercupColors.SurfaceStrong,
    onSurfaceVariant = PapercupColors.TextMuted,
    error = PapercupColors.Error,
    onError = Color(0xFF1A0408),
    errorContainer = Color(0xFF3D1118),
    onErrorContainer = Color(0xFFFFD8DE),
    outline = PapercupColors.Stroke,
    outlineVariant = PapercupColors.StrokeSoft,
)

val PapercupLightColorScheme = lightColorScheme()

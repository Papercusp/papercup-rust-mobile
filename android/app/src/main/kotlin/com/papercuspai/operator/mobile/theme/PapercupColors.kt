// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile.theme

import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

object PapercupColors {
    val Ink = Color(0xFF050812)
    val InkRaised = Color(0xFF0A111D)
    val Surface = Color(0xFF0E1725)
    val SurfaceStrong = Color(0xFF111D2D)
    val Stroke = Color(0xFF243244)
    val StrokeStrong = Color(0xFF36506A)
    val Text = Color(0xFFE6F3FF)
    val TextMuted = Color(0xFF8EA4B8)
    val Accent = Color(0xFF22D3EE)
    val AccentStrong = Color(0xFF67E8F9)
    val AccentSoft = Color(0x3322D3EE)
    val Success = Color(0xFF34D399)
    val SuccessSoft = Color(0x3034D399)
    val Warning = Color(0xFFFBBF24)
    val WarningSoft = Color(0x33FBBF24)
    val Error = Color(0xFFFB7185)
    val ErrorSoft = Color(0x33FB7185)
    val Info = Color(0xFF60A5FA)
    val InfoSoft = Color(0x2E60A5FA)

    val ScreenGradient = Brush.verticalGradient(
        listOf(
            Color(0xFF08111D),
            Color(0xFF050812),
            Color(0xFF02040A),
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
    tertiary = PapercupColors.Warning,
    onTertiary = Color(0xFF2A1C00),
    tertiaryContainer = Color(0xFF3B2B05),
    onTertiaryContainer = Color(0xFFFDE68A),
    error = PapercupColors.Error,
    onError = Color(0xFF31030B),
    errorContainer = Color(0xFF42101A),
    onErrorContainer = Color(0xFFFFCDD6),
    background = PapercupColors.Ink,
    onBackground = PapercupColors.Text,
    surface = PapercupColors.InkRaised,
    onSurface = PapercupColors.Text,
    surfaceVariant = PapercupColors.Surface,
    onSurfaceVariant = PapercupColors.TextMuted,
    outline = PapercupColors.Stroke,
    outlineVariant = PapercupColors.StrokeStrong,
    inverseSurface = Color(0xFFE6F3FF),
    inverseOnSurface = Color(0xFF07111D),
)

val PapercupLightColorScheme = lightColorScheme(
    primary = Color(0xFF007A8F),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFC8F7FF),
    onPrimaryContainer = Color(0xFF00323B),
    secondary = Color(0xFF087451),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFC7F9E5),
    onSecondaryContainer = Color(0xFF062A1F),
    tertiary = Color(0xFF8A5D00),
    onTertiary = Color.White,
    tertiaryContainer = Color(0xFFFFE7A3),
    onTertiaryContainer = Color(0xFF2B1D00),
    error = Color(0xFFB4233C),
    onError = Color.White,
    errorContainer = Color(0xFFFFD9DF),
    onErrorContainer = Color(0xFF3F0510),
    background = Color(0xFFF5FAFC),
    onBackground = Color(0xFF0B1724),
    surface = Color(0xFFFFFFFF),
    onSurface = Color(0xFF0B1724),
    surfaceVariant = Color(0xFFE5EEF4),
    onSurfaceVariant = Color(0xFF455666),
    outline = Color(0xFF8EA4B8),
    outlineVariant = Color(0xFFC9D6E0),
)

// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile.theme

import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

object PapercupColors {
    val Ink = Color(0xFF04080F)
    val InkRaised = Color(0xFF081421)
    val Surface = Color(0xFF081421)
    val SurfaceStrong = Color(0xFF0B1827)
    val Popover = Color(0xFF0B1827)
    val Stroke = Color(0x387DD3FC)
    val StrokeStrong = Color(0x577DD3FC)
    val StrokeSoft = Color(0x1F7DD3FC)
    val Text = Color(0xFFF3FBFF)
    val TextMuted = Color(0xBDCBD5E1)
    val TextFaint = Color(0xAD94A3B8)
    val Accent = Color(0xFF38BDF8)
    val AccentStrong = Color(0xFF7DD3FC)
    val AccentCool = Color(0xFFBAE6FD)
    val OperatorHeroCyan = Color(0xFF13F5FF)
    val AccentSoft = Color(0x2438BDF8)
    val Teal = Color(0xFF34D399)
    val TealSoft = Color(0x2434D399)
    val Gold = Color(0xFFF6C453)
    val GoldSoft = Color(0x24F6C453)
    val ButtonInk = Color(0xFF031118)
    val Success = Color(0xFF34D399)
    val SuccessSoft = Color(0x3034D399)
    val Warning = Color(0xFFF6C453)
    val WarningSoft = Color(0x33F6C453)
    val Error = Color(0xFFFB7185)
    val ErrorSoft = Color(0x33FB7185)
    val Info = AccentStrong
    val InfoSoft = Color(0x2E7DD3FC)

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

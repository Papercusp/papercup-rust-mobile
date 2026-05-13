// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile.theme

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp

val PapercupShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(12.dp),
    medium = RoundedCornerShape(16.dp),
    large = RoundedCornerShape(22.dp),
    extraLarge = RoundedCornerShape(28.dp),
)

val PapercupCardShape = RoundedCornerShape(22.dp)
val PapercupChipShape = RoundedCornerShape(999.dp)
val PapercupCameraShape = RoundedCornerShape(28.dp)

@Composable
fun PapercupTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = PapercupDarkColorScheme,
        typography = PapercupTypography,
        shapes = PapercupShapes,
        content = content,
    )
}

@Composable
fun PapercupScreen(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .drawBehind {
                drawRect(PapercupColors.ScreenGradient)
                drawRect(
                    Brush.radialGradient(
                        colors = listOf(
                            PapercupColors.Accent.copy(alpha = 0.24f),
                            Color.Transparent,
                        ),
                        center = Offset(size.width * 0.5f, -size.height * 0.08f),
                        radius = size.width * 1.45f,
                    ),
                )
            },
    ) {
        content()
    }
}

@Composable
fun PapercupScreenHeader(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    navigationIcon: (@Composable () -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit = {},
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .background(PapercupColors.HeaderGradient)
            .border(BorderStroke(1.dp, PapercupColors.StrokeSoft))
            .drawBehind {
                val y = size.height - 1.dp.toPx()
                drawLine(
                    color = PapercupColors.AccentStrong.copy(alpha = 0.46f),
                    start = Offset(16.dp.toPx(), y),
                    end = Offset(size.width * 0.52f, y),
                    strokeWidth = 1.dp.toPx(),
                )
                drawLine(
                    color = PapercupColors.Gold.copy(alpha = 0.24f),
                    start = Offset(size.width * 0.70f, y),
                    end = Offset(size.width - 16.dp.toPx(), y),
                    strokeWidth = 1.dp.toPx(),
                )
            }
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                modifier = Modifier.weight(1f),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                navigationIcon?.let {
                    it()
                    Spacer(Modifier.width(10.dp))
                }
                Column {
                    Text(
                        text = title,
                        style = MaterialTheme.typography.titleLarge,
                        color = PapercupColors.Text,
                    )
                    subtitle?.let {
                        Text(
                            text = it,
                            style = MaterialTheme.typography.labelSmall,
                            color = PapercupColors.TextFaint,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                }
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
                content = actions,
            )
        }
    }
}

fun Modifier.papercupCardChrome() =
    this
        .clip(PapercupCardShape)
        .background(PapercupColors.CardGradient)
        .border(BorderStroke(1.dp, PapercupColors.Stroke.copy(alpha = 0.72f)), PapercupCardShape)
        .drawBehind {
            val cyan = PapercupColors.AccentStrong.copy(alpha = 0.38f)
            val cyanSoft = PapercupColors.AccentStrong.copy(alpha = 0.26f)
            val gold = PapercupColors.Gold.copy(alpha = 0.30f)
            val goldSoft = PapercupColors.Gold.copy(alpha = 0.18f)
            val rail = 1.dp.toPx()
            val longRail = 84.dp.toPx()
            val shortRail = 72.dp.toPx()
            val rightRail = 104.dp.toPx()
            val dotInset = 16.dp.toPx()
            val haloRadius = 7.dp.toPx()
            val dotRadius = 1.6.dp.toPx()

            drawLine(cyan, Offset.Zero, Offset(longRail, 0f), strokeWidth = rail)
            drawLine(cyanSoft, Offset.Zero, Offset(0f, shortRail), strokeWidth = rail)
            drawLine(cyan, Offset(size.width - rightRail, 0f), Offset(size.width, 0f), strokeWidth = rail)
            drawLine(cyanSoft, Offset(size.width, 0f), Offset(size.width, shortRail), strokeWidth = rail)

            drawLine(gold, Offset(0f, size.height), Offset(longRail, size.height), strokeWidth = rail)
            drawLine(goldSoft, Offset(0f, size.height - shortRail), Offset(0f, size.height), strokeWidth = rail)
            drawLine(gold, Offset(size.width - rightRail, size.height), Offset(size.width, size.height), strokeWidth = rail)
            drawLine(goldSoft, Offset(size.width, size.height - shortRail), Offset(size.width, size.height), strokeWidth = rail)

            listOf(
                Offset(dotInset, dotInset),
                Offset(size.width - dotInset, dotInset),
                Offset(dotInset, size.height - dotInset),
                Offset(size.width - dotInset, size.height - dotInset),
            ).forEach { dot ->
                drawCircle(PapercupColors.Gold.copy(alpha = 0.18f), radius = haloRadius, center = dot)
                drawCircle(PapercupColors.AccentStrong.copy(alpha = 0.92f), radius = dotRadius, center = dot)
            }
        }

@Composable
fun PapercupCard(
    modifier: Modifier = Modifier,
    accent: Color = PapercupColors.AccentSoft,
    contentPadding: PaddingValues = PaddingValues(16.dp),
    content: @Composable () -> Unit,
) {
    ElevatedCard(
        modifier = modifier.fillMaxWidth().papercupCardChrome(),
        shape = PapercupCardShape,
        colors = CardDefaults.elevatedCardColors(
            containerColor = PapercupColors.Surface.copy(alpha = 0.92f),
            contentColor = MaterialTheme.colorScheme.onSurface,
        ),
        elevation = CardDefaults.elevatedCardElevation(defaultElevation = 8.dp),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(PapercupCardShape)
                .background(accent)
                .padding(contentPadding),
        ) {
            content()
        }
    }
}

@Composable
fun PapercupPanel(
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(16.dp),
    content: @Composable () -> Unit,
) {
    Card(
        modifier = modifier.fillMaxWidth().papercupCardChrome(),
        shape = PapercupCardShape,
        colors = CardDefaults.cardColors(
            containerColor = PapercupColors.InkRaised.copy(alpha = 0.88f),
            contentColor = MaterialTheme.colorScheme.onSurface,
        ),
    ) {
        Box(Modifier.padding(contentPadding)) { content() }
    }
}

@Composable
fun PapercupSectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text.uppercase(),
        modifier = modifier,
        style = MaterialTheme.typography.labelSmall,
        color = PapercupColors.TextMuted,
    )
}

@Composable
fun PapercupCardHeader(
    title: String,
    modifier: Modifier = Modifier,
    meta: String? = null,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PapercupStatusChip(text = title, containerColor = PapercupColors.AccentSoft, contentColor = PapercupColors.AccentStrong)
        meta?.let {
            PapercupStatusChip(text = it, containerColor = PapercupColors.WarningSoft, contentColor = PapercupColors.Warning)
        }
    }
}

@Composable
fun PapercupMetaText(text: String, modifier: Modifier = Modifier, monospace: Boolean = false) {
    Text(
        text = text,
        modifier = modifier,
        style = MaterialTheme.typography.bodySmall,
        color = PapercupColors.TextMuted,
        fontFamily = if (monospace) FontFamily.Monospace else FontFamily.Default,
    )
}

@Composable
fun PapercupStatusChip(
    text: String,
    modifier: Modifier = Modifier,
    containerColor: Color = PapercupColors.AccentSoft,
    contentColor: Color = PapercupColors.AccentStrong,
    borderColor: Color = contentColor.copy(alpha = 0.45f),
    onClick: (() -> Unit)? = null,
) {
    val normalized = text.lowercase().replace('_', ' ')
    val pulses = normalized.contains("progress") ||
        normalized.contains("validating") ||
        normalized.contains("running") ||
        normalized.contains("pairing") ||
        normalized.contains("scanning") ||
        normalized == "live"
    val pulseAlpha by rememberInfiniteTransition(label = "status-pulse").animateFloat(
        initialValue = 0.42f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1_200),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "status-pulse-alpha",
    )
    AssistChip(
        onClick = onClick ?: {},
        label = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (pulses) {
                    Box(
                        modifier = Modifier
                            .size(6.dp)
                            .clip(PapercupChipShape)
                            .background(contentColor.copy(alpha = pulseAlpha)),
                    )
                    Spacer(Modifier.width(6.dp))
                }
                Text(text, style = MaterialTheme.typography.labelSmall)
            }
        },
        modifier = modifier.semantics { contentDescription = "Status $text" },
        shape = PapercupChipShape,
        border = BorderStroke(1.dp, borderColor),
        colors = AssistChipDefaults.assistChipColors(
            containerColor = containerColor,
            labelColor = contentColor,
        ),
    )
}

@Composable
fun PapercupChipRow(
    modifier: Modifier = Modifier,
    content: @Composable RowScope.() -> Unit,
) {
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        content = content,
    )
}

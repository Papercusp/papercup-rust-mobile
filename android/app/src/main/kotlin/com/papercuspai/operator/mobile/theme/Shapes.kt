// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile.theme

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
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
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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
            .background(PapercupColors.ScreenGradient),
    ) {
        content()
    }
}

fun Modifier.papercupCardChrome() =
    this.border(BorderStroke(1.dp, PapercupColors.Stroke.copy(alpha = 0.72f)), PapercupCardShape)

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
    AssistChip(
        onClick = onClick ?: {},
        label = { Text(text, style = MaterialTheme.typography.labelSmall) },
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

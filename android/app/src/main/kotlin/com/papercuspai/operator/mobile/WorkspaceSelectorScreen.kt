// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import com.papercuspai.operator.mobile.theme.PapercupCard
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupMetaText
import com.papercuspai.operator.mobile.theme.PapercupScreenHeader
import com.papercuspai.operator.mobile.theme.PapercupStatusChip
import kotlinx.coroutines.launch
import uniffi.papercup.ApiException
import uniffi.papercup.OperatorClient
import uniffi.papercup.Workspace

@Composable
fun WorkspaceSelectorScreen(
    creds: DeviceCredentials,
    onBack: () -> Unit,
    onWorkspaceSwitched: (DeviceCredentials) -> Unit,
) {
    val activity = rememberFragmentActivity()
    val scope = rememberCoroutineScope()
    var workspaces by remember { mutableStateOf<List<Workspace>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var busyWorkspaceId by remember { mutableStateOf<String?>(null) }
    var currentWorkspaceId by remember { mutableStateOf(creds.workspaceId) }

    suspend fun loadWorkspaces() {
        try {
            workspaces = creds.client().listWorkspaces()
            error = null
        } catch (e: ApiException) {
            error = HumanError.describe(e, "Loading workspaces")
        } catch (t: Throwable) {
            error = HumanError.describe(t, "Loading workspaces")
        }
    }

    LaunchedEffect(creds.deviceToken) {
        currentWorkspaceId = creds.workspaceId
        loadWorkspaces()
    }

    val currentWorkspaceName = workspaces
        ?.firstOrNull { it.id == currentWorkspaceId }
        ?.name
        ?: creds.workspaceId

    Scaffold(
        topBar = {
            PapercupScreenHeader(
                title = "Workspace selector",
                subtitle = if (workspaces == null) "Loading…" else currentWorkspaceName,
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back",
                        )
                    }
                },
            )
        },
        containerColor = PapercupColors.Ink,
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .background(PapercupColors.ScreenGradient)
                .padding(padding)
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            contentPadding = PaddingValues(vertical = 12.dp),
        ) {
            error?.let { message ->
                item {
                    PapercupCard(accent = PapercupColors.ErrorSoft) {
                        Text(
                            text = message,
                            color = PapercupColors.Error,
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                }
            }

            when (val ws = workspaces) {
                null -> item {
                    WorkspaceLoadingCard()
                }

                else -> {
                    if (ws.isEmpty()) {
                        item {
                            EmptyWorkspaceCard()
                        }
                    } else {
                        items(ws, key = { it.id }) { workspace ->
                            WorkspaceCard(
                                workspace = workspace,
                                active = workspace.id == currentWorkspaceId,
                                switching = workspace.id == busyWorkspaceId,
                                enabled = busyWorkspaceId == null && workspace.id != currentWorkspaceId,
                                onClick = {
                                    scope.launch {
                                        busyWorkspaceId = workspace.id
                                        try {
                                            val fresh = creds.switchWorkspace(
                                                workspace.id,
                                                gatedWorkspaceClient(creds, activity)::workspaceSwitch,
                                                onWorkspaceSwitched,
                                            )
                                            currentWorkspaceId = fresh.workspaceId
                                        } catch (cancelled: kotlinx.coroutines.CancellationException) {
                                            throw cancelled
                                        } catch (t: Throwable) {
                                            error = HumanError.describe(t, "Switching workspace")
                                        } finally {
                                            busyWorkspaceId = null
                                        }
                                    }
                                },
                            )
                        }
                    }

                    if (ws.size > 1 && currentWorkspaceId.isNotBlank()) {
                        item {
                            Text(
                                text = "Switching workspaces re-issues your device token with the new workspace claim. Existing screens refresh automatically.",
                                style = MaterialTheme.typography.bodySmall,
                                color = PapercupColors.TextMuted,
                                modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun WorkspaceLoadingCard() {
    PapercupCard {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CircularProgressIndicator(
                modifier = Modifier.size(18.dp),
                strokeWidth = 2.dp,
                color = PapercupColors.AccentStrong,
            )
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    text = "Loading workspaces…",
                    style = MaterialTheme.typography.bodyMedium,
                    color = PapercupColors.Text,
                )
                PapercupMetaText(text = "Fetching switch targets and current claim.")
            }
        }
    }
}

@Composable
private fun EmptyWorkspaceCard() {
    PapercupCard {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = "No workspaces available.",
                style = MaterialTheme.typography.bodyMedium,
                color = PapercupColors.Text,
            )
            PapercupMetaText(text = "Pair against another desktop or refresh from settings.")
        }
    }
}

@Composable
private fun WorkspaceCard(
    workspace: Workspace,
    active: Boolean,
    switching: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    PapercupCard(
        modifier = Modifier.clickable(enabled = enabled, onClick = onClick),
        accent = if (active) PapercupColors.AccentSoft else PapercupColors.InkRaised,
        contentPadding = PaddingValues(0.dp),
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top,
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        text = workspace.name,
                        style = MaterialTheme.typography.bodyLarge,
                        color = PapercupColors.Text,
                    )
                    PapercupMetaText(text = workspace.id, monospace = true)
                }
                when {
                    switching -> Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(14.dp),
                            strokeWidth = 2.dp,
                            color = PapercupColors.AccentStrong,
                        )
                        PapercupMetaText(text = "Switching…")
                    }

                    active -> PapercupStatusChip(
                        text = "Current",
                        containerColor = PapercupColors.AccentSoft,
                        contentColor = PapercupColors.AccentStrong,
                    )

                    else -> PapercupStatusChip(
                        text = "Switch",
                        containerColor = PapercupColors.WarningSoft,
                        contentColor = PapercupColors.Warning,
                    )
                }
            }
            HorizontalDivider(color = PapercupColors.StrokeSoft.copy(alpha = 0.55f))
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                PapercupMetaText(
                    text = workspaceActivityLabel(workspace.lastActivityAt) ?: "No recent activity",
                )
                PapercupMetaText(
                    text = if (active) "Active workspace" else "Tap to switch",
                )
            }
        }
    }
}

@Composable
internal fun rememberFragmentActivity(): FragmentActivity? {
    val context = androidx.compose.ui.platform.LocalContext.current
    return remember(context) {
        var current: android.content.Context = context
        while (current is android.content.ContextWrapper && current !is FragmentActivity) {
            current = current.baseContext
        }
        current as? FragmentActivity
    }
}

internal fun gatedWorkspaceClient(creds: DeviceCredentials, activity: FragmentActivity?): OperatorClient =
    creds.client().also { client ->
        activity?.let { client.setBiometricPrompt(BiometricGate(it)) }
    }

private fun workspaceActivityLabel(activityAtMs: Long?): String? {
    val ts = activityAtMs ?: return null
    val diff = (System.currentTimeMillis() - ts).coerceAtLeast(0)
    val seconds = diff / 1000
    return when {
        seconds < 60 -> "active just now"
        seconds < 3600 -> "active ${seconds / 60}m ago"
        seconds < 86_400 -> "active ${seconds / 3600}h ago"
        else -> "active ${seconds / 86_400}d ago"
    }
}

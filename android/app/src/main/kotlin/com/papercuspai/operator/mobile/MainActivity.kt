// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.os.Bundle
import android.Manifest
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.tasks.await
import com.papercuspai.operator.mobile.theme.PapercupTheme
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import com.papercuspai.operator.mobile.theme.PapercupCard
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupMetaText
import com.papercuspai.operator.mobile.theme.PapercupCardHeader
import com.papercuspai.operator.mobile.theme.PapercupStatusChip
import com.papercuspai.operator.mobile.theme.PapercupScreenHeader
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.clickable
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.ui.draw.clip
import androidx.compose.material3.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import uniffi.papercup.ApiException
import uniffi.papercup.Harness
import uniffi.papercup.SyncException
import uniffi.papercup.SyncStream
import uniffi.papercup.version
import java.time.Duration
import java.time.Instant
import java.time.format.DateTimeParseException

class MainActivity : androidx.fragment.app.FragmentActivity() {
    private val deepLinkSlug = mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val store = CredentialStore(applicationContext)
        ensureNotificationChannel(applicationContext)
        deepLinkSlug.value = intent?.getStringExtra(EXTRA_DEEPLINK_SLUG)
        setContent {
            PapercupTheme {
                AppRoot(store, deepLinkSlug)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra(EXTRA_DEEPLINK_SLUG)?.let { deepLinkSlug.value = it }
    }
}

@Composable
private fun AppRoot(store: CredentialStore, deepLinkSlug: androidx.compose.runtime.MutableState<String?>) {
    val context = LocalContext.current
    var creds by remember { mutableStateOf(store.load()) }
    var route by remember { mutableStateOf<Route>(Route.Operator) }
    var liveTick by remember { mutableStateOf(0) }
    var lastInvalidate by remember { mutableStateOf<String?>(null) }

    // Deep-link from a tapped notification → harness detail. Cleared
    // immediately so a back-press doesn't re-navigate on recomposition.
    LaunchedEffect(deepLinkSlug.value) {
        val slug = deepLinkSlug.value ?: return@LaunchedEffect
        if (creds != null) route = Route.Detail(slug)
        deepLinkSlug.value = null
    }

    // Android 13+ runtime grant for showing notifications. Best-effort:
    // a denied permission just means pushes silently won't appear.
    val notifLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { /* ignored */ }
    LaunchedEffect(Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            notifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    val current = creds
    if (current == null) {
        PairScreen(onPaired = { fresh ->
            store.save(fresh)
            creds = fresh
            route = Route.Operator
        })
        return
    }

    // Phase 3 — shared in-memory cache. Registers exactly the query
    // names the backend actually emits invalidates for (verified
    // against papercup-rust-server: sync_invalidate::notify call
    // sites). Subscribes a CacheSubscriber that bumps liveTick so
    // every screen with a `liveTick`-keyed task() refreshes when
    // any registered cache entry refetches.
    val cache = remember(current.deviceToken) {
        uniffi.papercup.SyncCache(current.client())
    }
    DisposableEffect(current.deviceToken) {
        listOf(
            "toastLog.recent",
            "auditLog.recent",
            "operatorPauseFlag",
            "harnessIdentity",
        ).forEach { cache.registerQuery(it) }
        cache.subscribe(object : uniffi.papercup.CacheSubscriber {
            override fun `onUpdate`(`update`: uniffi.papercup.CacheUpdate) {
                // Either Updated or Failed bumps the tick; failed
                // refetches still want screens to re-render their
                // error/loading state.
                liveTick += 1
                if (update is uniffi.papercup.CacheUpdate.Updated) {
                    lastInvalidate = update.name
                }
            }
        })
        onDispose { cache.close() }
    }

    // Single SSE subscription, lives for the duration of the paired
    // session — pumps invalidations into the cache + bumps the
    // liveTick the UI reads for transient "live · X" pills.
    DisposableEffect(current.deviceToken) {
        val stream = SyncStream(current.server, current.deviceToken)
        val job = kotlinx.coroutines.MainScope().launch {
            try {
                while (true) {
                    val ev = stream.nextEvent()
                    lastInvalidate = ev.name
                    cache.handleInvalidate(ev.name)
                    if (ev.name.startsWith("harness")) {
                        liveTick += 1
                    }
                }
            } catch (_: CancellationException) {
            } catch (_: SyncException) {
            }
        }
        onDispose {
            stream.disconnect()
            stream.close()
            job.cancel()
        }
    }

    // Phase 5a: keep the FCM token registered with the operator so the
    // desktop can push to this device. Idempotent server-side; only
    // hits the wire on credential change or app cold-start.
    LaunchedEffect(current.deviceToken) {
        try {
            val token = FirebaseMessaging.getInstance().token.await()
            current.client()
                .registerPush(platform = "fcm", token = token)
        } catch (_: Throwable) {
            // Ignore here; PushService.onNewToken will retry on rotation.
        }
    }

    // Phase 7a: heartbeat tick while the app is alive so the desktop's
    // 'paired phone is connected' badge stays green. 60s is plenty —
    // backend doesn't expire fast.
    LaunchedEffect(current.deviceToken) {
        val client = current.client()
        while (true) {
            try { client.heartbeat() } catch (_: Throwable) {}
            kotlinx.coroutines.delay(60_000)
        }
    }

    val voice = remember(current.deviceToken) { VoiceManager(context, current) }
    DisposableEffect(current.deviceToken) { onDispose { voice.stop() } }

    // Voice intent dispatch — every `browser: 'required'` client-tool
    // call from the EL agent surfaces here and maps to native action.
    LaunchedEffect(voice) {
        voice.intents.collect { intent ->
            when (intent) {
                is VoiceManager.Intent.NavigateHarness ->
                    route = Route.Detail(intent.slug)
                is VoiceManager.Intent.NavigateTab -> route = when (intent.tab) {
                    VoiceManager.Intent.Tab.Operator -> Route.Operator
                    VoiceManager.Intent.Tab.Harnesses -> Route.List
                    VoiceManager.Intent.Tab.Activity -> Route.Activity
                    VoiceManager.Intent.Tab.Settings -> Route.Settings
                }
                is VoiceManager.Intent.NavigateVoiceSettings ->
                    route = Route.VoiceSettings
                is VoiceManager.Intent.NavigateStandingApprovals ->
                    route = Route.StandingApprovals
                VoiceManager.Intent.Pause ->
                    runCatching { current.client().pauseSet(true) }
                VoiceManager.Intent.Resume ->
                    runCatching { current.client().pauseSet(false) }
                VoiceManager.Intent.ClaimVoice ->
                    runCatching { current.client().voiceLeaseClaim() }
                is VoiceManager.Intent.VoiceSetMode -> {
                    // mode=on → start, mode=off → stop. Anything else: log.
                    when (intent.mode.lowercase()) {
                        "on", "start", "listening" -> voice.start()
                        "off", "stop", "idle" -> voice.stop()
                        else -> Log.i("PapercupVoice", "voice.set-mode unrecognized: ${intent.mode}")
                    }
                }
                is VoiceManager.Intent.WorkspaceSwitch -> {
                    runCatching { current.client().workspaceSwitch(intent.workspaceId) }
                }
            }
        }
    }

    // Phase 10g + Phase 5 foreground service: wake-word listener runs
    // out-of-process via WakeWordService so 'hey papercup' fires even
    // when the app is backgrounded or screen-off. Wake events arrive
    // as ACTION_WAKE broadcasts that we route into voice.start().
    // Service is a no-op without PICOVOICE_ACCESS_KEY.
    val voiceState by voice.state.collectAsState()
    DisposableEffect(current.deviceToken) {
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(c: android.content.Context?, intent: android.content.Intent?) {
                if (intent?.action == WakeWordService.ACTION_WAKE) {
                    voice.start()
                }
            }
        }
        val filter = android.content.IntentFilter(WakeWordService.ACTION_WAKE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, android.content.Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
        // Only start the microphone-FGS wake-word service when both:
        //   - Picovoice key is configured (otherwise the engine is a no-op anyway), AND
        //   - RECORD_AUDIO is granted (FGS type=microphone on API 34+ requires it; the
        //     OS throws SecurityException at startForeground otherwise — crashed the
        //     app on launch in the dormant-key case before this gate).
        val hasRecordAudio = androidx.core.content.ContextCompat.checkSelfPermission(
            context,
            android.Manifest.permission.RECORD_AUDIO,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        val wakeWordStarted = WakeWordEngine.isConfigured() && hasRecordAudio
        if (wakeWordStarted) {
            WakeWordService.start(context)
        }
        onDispose {
            try { context.unregisterReceiver(receiver) } catch (_: Throwable) {}
            if (wakeWordStarted) {
                WakeWordService.stop(context)
            }
        }
    }
    // Throttle the service while voice is actively listening so
    // SpeechRecognizer doesn't fight Porcupine over the mic. Gated
    // by the same caller-side check as the DisposableEffect above —
    // never (re-)start FGS-microphone without RECORD_AUDIO + key.
    LaunchedEffect(voiceState, current.deviceToken) {
        val canRun = WakeWordEngine.isConfigured() &&
            androidx.core.content.ContextCompat.checkSelfPermission(
                context, android.Manifest.permission.RECORD_AUDIO,
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (!canRun) return@LaunchedEffect
        if (voiceState is VoiceManager.State.Idle) {
            WakeWordService.start(context)
        } else {
            WakeWordService.stop(context)
        }
    }

    val onForget = remember<() -> Unit>(store) {
        {
            store.clear()
            creds = null
        }
    }
    val onWorkspaceSwitched: (DeviceCredentials) -> Unit = remember(store) {
        { fresh ->
            store.save(fresh)
            creds = fresh
        }
    }
    val scope = rememberCoroutineScope()
    val monitor = remember(current.deviceToken) { ConnectionMonitor(scope, current) }
    DisposableEffect(current.deviceToken) {
        monitor.start()
        onDispose { monitor.stop() }
    }

    when (val r = route) {
        is Route.Detail -> HarnessDetailScreen(
            creds = current,
            slug = r.slug,
            invalidationTick = liveTick,
            onBack = { route = Route.List },
            onOpenRunLog = { route = Route.RunLog(r.slug) },
        )
        is Route.RunLog -> RunLogScreen(
            creds = current,
            slug = r.slug,
            onBack = { route = Route.Detail(r.slug) },
        )
        Route.StandingApprovals -> StandingApprovalsScreen(creds = current, onBack = { route = Route.Settings })
        Route.VoiceSettings -> VoiceSettingsScreen(onBack = { route = Route.Settings })
        Route.Diagnostics -> DiagnosticsScreen(
            creds = current,
            monitor = monitor,
            onBack = { route = Route.Settings },
            onOpenPushTapTest = { route = Route.PushTapTest },
        )
        Route.PushTapTest -> PushTapTestScreen(
            onBack = { route = Route.Diagnostics },
            onOpenHarnessDetail = { slug -> route = Route.Detail(slug) },
            onOpenRunLog = { slug -> route = Route.RunLog(slug) },
            onOpenOperator = { route = Route.Operator },
            onOpenInbox = { route = Route.Activity },
        )
        Route.WorkspaceSelector -> WorkspaceSelectorScreen(
            creds = current,
            onBack = { route = Route.Settings },
            onWorkspaceSwitched = onWorkspaceSwitched,
        )
        Route.NotificationHistory -> ActivityScreen(
            creds = current,
            invalidationTick = liveTick,
            onSelectHarness = { slug -> route = Route.Detail(slug) },
            mode = ActivitySurface.History,
            onOpenRecentActions = { route = Route.RecentActions },
            onBack = { route = Route.Activity },
        )
        Route.RecentActions -> ActivityScreen(
            creds = current,
            invalidationTick = liveTick,
            onSelectHarness = { slug -> route = Route.Detail(slug) },
            mode = ActivitySurface.Actions,
            onOpenHistory = { route = Route.NotificationHistory },
            onBack = { route = Route.Activity },
        )
        Route.Operator, Route.List, Route.Running, Route.Activity, Route.Settings -> PairedShell(
            current = current,
            voice = voice,
            liveTick = liveTick,
            lastInvalidate = lastInvalidate,
            monitor = monitor,
            route = r,
            onRouteChange = { route = it },
            onSelectHarness = { slug -> route = Route.Detail(slug) },
            onOpenWorkspaceSelector = { route = Route.WorkspaceSelector },
            onOpenStandingApprovals = { route = Route.StandingApprovals },
            onOpenVoiceSettings = { route = Route.VoiceSettings },
            onOpenDiagnostics = { route = Route.Diagnostics },
            onForget = onForget,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PairedShell(
    current: DeviceCredentials,
    voice: VoiceManager,
    liveTick: Int,
    lastInvalidate: String?,
    monitor: ConnectionMonitor,
    route: Route,
    onRouteChange: (Route) -> Unit,
    onSelectHarness: (String) -> Unit,
    onOpenWorkspaceSelector: () -> Unit,
    onOpenStandingApprovals: () -> Unit,
    onOpenVoiceSettings: () -> Unit,
    onOpenDiagnostics: () -> Unit,
    onForget: () -> Unit,
) {
    val connState by monitor.state.collectAsState()
    val voiceStateForBanner by voice.state.collectAsState()
    var pendingCardBadgeCount by remember { mutableIntStateOf(0) }
    var recentToastBadgeCount by remember { mutableIntStateOf(0) }

    suspend fun refreshNavBadges() {
        val client = current.client()
        try {
            pendingCardBadgeCount = client.listOperatorCards().size
        } catch (_: Throwable) {
            // Keep the last known badge count; the screen itself surfaces load errors.
        }
        try {
            recentToastBadgeCount = client.recentNotifications().count(::isAttentionToast)
        } catch (_: Throwable) {
            // Keep the last known badge count; the screen itself surfaces load errors.
        }
    }

    LaunchedEffect(current.deviceToken, liveTick) {
        refreshNavBadges()
    }
    LaunchedEffect(current.deviceToken) {
        while (isActive) {
            delay(30_000)
            refreshNavBadges()
        }
    }
    var offlineNowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(connState.status, connState.offlineSinceMs) {
        if (connState.status != ConnStatus.Offline) return@LaunchedEffect
        while (isActive) {
            offlineNowMs = System.currentTimeMillis()
            delay(1_000)
        }
    }
    Scaffold(
        topBar = {
            Column {
                GlobalPausedBanner(creds = current, liveTick = liveTick)
                if (connState.status == ConnStatus.Offline) {
                    OfflineBanner(
                        offlineSinceMs = connState.offlineSinceMs,
                        nowMs = offlineNowMs,
                    )
                }
                (voiceStateForBanner as? VoiceManager.State.Failed)?.let { failed ->
                    VoiceErrorBanner(
                        failed = failed,
                        onDismiss = { voice.stop() },
                        onRetry = { voice.start() },
                    )
                }
            }
        },
        bottomBar = {
            MobileBottomNav(
                selected = route,
                badgeCounts = ShellBadgeCounts(
                    pendingCards = pendingCardBadgeCount,
                    recentToasts = recentToastBadgeCount,
                ),
                onRouteChange = onRouteChange,
            )
        },
        // Voice FAB shown on every top-level tab, matching the retired
        // Tauri mobile shell's fixed right-side voice pill.
        floatingActionButton = { VoiceFab(voice) },
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            when (route) {
                Route.Operator -> OperatorScreen(
                    creds = current,
                    voice = voice,
                    liveTick = liveTick,
                    onSelectHarness = onSelectHarness,
                )
                Route.List -> HarnessListScreen(
                    creds = current,
                    liveTick = liveTick,
                    lastInvalidate = lastInvalidate,
                    voice = voice,
                    onSelect = onSelectHarness,
                )
                Route.Running -> RunningScreen(
                    creds = current,
                    liveTick = liveTick,
                    onSelectHarness = onSelectHarness,
                )
                Route.Activity -> ActivityScreen(
                    creds = current,
                    invalidationTick = liveTick,
                    onSelectHarness = onSelectHarness,
                    mode = ActivitySurface.Notifications,
                    onOpenHistory = { onRouteChange(Route.NotificationHistory) },
                    onOpenRecentActions = { onRouteChange(Route.RecentActions) },
                )
                Route.Settings -> SettingsScreen(
                    creds = current,
                    onOpenWorkspaceSelector = onOpenWorkspaceSelector,
                    onOpenStandingApprovals = onOpenStandingApprovals,
                    onOpenVoiceSettings = onOpenVoiceSettings,
                    onOpenDiagnostics = onOpenDiagnostics,
                    onForget = onForget,
                )
                else -> {}
            }
        }
    }
}

@Composable
private fun GlobalPausedBanner(creds: DeviceCredentials, liveTick: Int) {
    var info by remember { mutableStateOf<uniffi.papercup.PauseInfo?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    suspend fun refreshPauseInfo() {
        try {
            info = creds.client().pauseGet()
        } catch (_: Throwable) {
        }
    }

    LaunchedEffect(creds.deviceToken, liveTick) {
        refreshPauseInfo()
    }
    LaunchedEffect(creds.deviceToken) {
        while (isActive) {
            delay(8_000)
            refreshPauseInfo()
        }
    }

    val pauseInfo = info ?: return
    if (!pauseInfo.paused) return

    val detail = listOfNotNull(
        shortPauseActor(pauseInfo.by)?.let { "by $it" },
        pauseInfo.at?.let(::formatPauseAge),
    ).joinToString(" · ")

    Surface(
        color = PapercupColors.WarningSoft,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "⏸",
                style = MaterialTheme.typography.titleMedium,
                color = PapercupColors.Warning,
            )
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = "Operator paused",
                    style = MaterialTheme.typography.bodyMedium,
                    color = PapercupColors.Warning,
                )
                if (detail.isNotEmpty()) {
                    Text(
                        text = detail,
                        style = MaterialTheme.typography.bodySmall,
                        color = PapercupColors.Warning.copy(alpha = 0.82f),
                    )
                }
            }
            TextButton(
                onClick = {
                    if (busy) return@TextButton
                    busy = true
                    scope.launch {
                        try {
                            creds.client().pauseSet(false)
                            refreshPauseInfo()
                        } catch (_: Throwable) {
                        } finally {
                            busy = false
                        }
                    }
                },
                enabled = !busy,
                colors = ButtonDefaults.textButtonColors(contentColor = PapercupColors.Warning),
            ) {
                Text(if (busy) "…" else "Resume")
            }
        }
    }
}

private fun shortPauseActor(by: String?): String? {
    if (by.isNullOrBlank()) return null
    if (by.startsWith("device:")) return "phone"
    val at = by.indexOf('@')
    return if (at > 0) by.slice(0 until at) else by
}

private fun formatPauseAge(iso: String): String {
    val instant = try {
        Instant.parse(iso)
    } catch (_: DateTimeParseException) {
        return iso
    }
    val seconds = Duration.between(instant, Instant.now()).seconds
    if (seconds < 0) return iso
    return when {
        seconds < 60 -> "${seconds}s ago"
        seconds < 3_600 -> "${seconds / 60}m ago"
        seconds < 86_400 -> "${seconds / 3_600}h ago"
        else -> "${seconds / 86_400}d ago"
    }
}

private data class ShellBadgeCounts(
    val pendingCards: Int = 0,
    val recentToasts: Int = 0,
)

private enum class NavBadgeTone { Info, Attention }

private data class BottomNavItem(
    val route: Route,
    val glyph: String,
    val label: String,
    val badgeCount: Int,
    val badgeTone: NavBadgeTone,
)

private fun isAttentionToast(toast: uniffi.papercup.Toast): Boolean {
    return when (toast.level.lowercase()) {
        "error", "warning", "warn" -> true
        else -> false
    }
}

private fun formatOfflineDuration(offlineSinceMs: Long?, nowMs: Long): String {
    val since = offlineSinceMs ?: return ""
    val seconds = ((nowMs - since) / 1_000).coerceAtLeast(1)
    return when {
        seconds < 60 -> "${seconds}s"
        seconds < 3_600 -> "${seconds / 60}m"
        else -> "${seconds / 3_600}h"
    }
}

@Composable
private fun OfflineBanner(offlineSinceMs: Long?, nowMs: Long) {
    val duration = formatOfflineDuration(offlineSinceMs, nowMs)
    Surface(
        color = MaterialTheme.colorScheme.errorContainer,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "●",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onErrorContainer,
            )
            Text(
                text = "Desktop offline",
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onErrorContainer,
            )
            if (duration.isNotEmpty()) {
                Text(
                    text = duration,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onErrorContainer.copy(alpha = 0.80f),
                )
            }
        }
    }
}

@Composable
private fun MobileBottomNav(
    selected: Route,
    badgeCounts: ShellBadgeCounts,
    onRouteChange: (Route) -> Unit,
) {
    val items = listOf(
        BottomNavItem(Route.Operator, "●", stringResource(R.string.tab_operator), badgeCounts.pendingCards, NavBadgeTone.Info),
        BottomNavItem(Route.List, "⌘", stringResource(R.string.tab_harnesses), 0, NavBadgeTone.Info),
        BottomNavItem(Route.Running, "▶", stringResource(R.string.tab_running), 0, NavBadgeTone.Info),
        BottomNavItem(Route.Activity, "◆", stringResource(R.string.tab_activity), badgeCounts.recentToasts, NavBadgeTone.Attention),
        BottomNavItem(Route.Settings, "⚙", stringResource(R.string.tab_settings), 0, NavBadgeTone.Info),
    )

    // Wrap in Surface so the Scaffold's FAB-anchor measurement
    // includes the bar's actual rendered height + so we sit above
    // page content in z-order (raw Row with .background() lets
    // sibling FABs slide visually underneath on some devices).
    // windowInsetsPadding(systemBars.only(bottom)) pushes content
    // above the system gesture bar on phones like the Fold5.
    Surface(
        color = Color.Transparent,
        modifier = Modifier
            .fillMaxWidth()
            .background(PapercupColors.HeaderGradient)
            .border(1.dp, PapercupColors.StrokeSoft),
        tonalElevation = 3.dp,
        shadowElevation = 3.dp,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .windowInsetsPadding(
                    WindowInsets.systemBars.only(WindowInsetsSides.Bottom)
                )
                .padding(bottom = 4.dp, top = 6.dp, start = 6.dp, end = 6.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            items.forEach { item ->
                val active = selected == item.route
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(16.dp))
                        .background(if (active) PapercupColors.AccentSoft else Color.Transparent)
                        .clickable { onRouteChange(item.route) }
                        .semantics {
                            contentDescription = item.label
                            role = androidx.compose.ui.semantics.Role.Button
                        }
                        .padding(vertical = 6.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(1.dp),
                ) {
                    Box {
                        Text(
                            text = item.glyph,
                            style = MaterialTheme.typography.titleMedium,
                            color = if (active) PapercupColors.AccentStrong else PapercupColors.TextFaint,
                        )
                        NavBadge(
                            count = item.badgeCount,
                            tone = item.badgeTone,
                            modifier = Modifier.align(Alignment.TopEnd).offset(x = 10.dp, y = (-4).dp),
                        )
                    }
                    Text(
                        text = item.label.uppercase(),
                        style = MaterialTheme.typography.labelSmall,
                        color = if (active) PapercupColors.AccentStrong else PapercupColors.TextFaint,
                    )
                }
            }
        }
    }
}

@Composable
private fun NavBadge(
    count: Int,
    tone: NavBadgeTone,
    modifier: Modifier = Modifier,
) {
    if (count <= 0) return
    val container = when (tone) {
        NavBadgeTone.Attention -> PapercupColors.Error
        NavBadgeTone.Info -> PapercupColors.Accent
    }
    val content = when (tone) {
        NavBadgeTone.Attention -> Color.White
        NavBadgeTone.Info -> PapercupColors.ButtonInk
    }
    Surface(
        modifier = modifier
            .height(16.dp)
            .defaultMinSize(minWidth = 16.dp),
        shape = RoundedCornerShape(999.dp),
        color = container,
        contentColor = content,
    ) {
        Box(
            modifier = Modifier.padding(horizontal = 4.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = if (count > 99) "99+" else count.toString(),
                style = MaterialTheme.typography.labelSmall,
                color = content,
            )
        }
    }
}

private sealed interface Route {
    /// Bottom-nav primary destinations.
    data object Operator : Route
    data object List : Route
    data object Running : Route
    data object Activity : Route
    data object Settings : Route

    /// Pushed routes (not in bottom nav).
    data class Detail(val slug: String) : Route
    data class RunLog(val slug: String) : Route
    data object StandingApprovals : Route
    data object VoiceSettings : Route
    data object Diagnostics : Route
    data object PushTapTest : Route
    data object WorkspaceSelector : Route
    data object NotificationHistory : Route
    data object RecentActions : Route
}

private sealed interface ScreenState {
    data object Loading : ScreenState
    data class Ready(val harnesses: List<Harness>) : ScreenState
    data class Failed(val message: String) : ScreenState
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HarnessListScreen(
    creds: DeviceCredentials,
    liveTick: Int,
    lastInvalidate: String?,
    voice: VoiceManager,
    onSelect: (String) -> Unit,
) {
    var state by remember { mutableStateOf<ScreenState>(ScreenState.Loading) }

    LaunchedEffect(creds.deviceToken, liveTick) {
        state = ScreenState.Loading
        state = try {
            val client = creds.client()
            ScreenState.Ready(client.listHarnesses())
        } catch (e: ApiException) {
            ScreenState.Failed("API: ${e::class.simpleName}: ${e.message ?: "no detail"}")
        } catch (t: Throwable) {
            ScreenState.Failed("Unexpected: ${t::class.simpleName}: ${t.message ?: "no detail"}")
        }
    }

    Scaffold(
        // Voice FAB is hoisted to PairedShell so it's visible on every
        // top-level tab — not just this one.
        topBar = {
            PapercupScreenHeader(
                title = "Harnesses",
                subtitle = when (val currentState = state) {
                    ScreenState.Loading -> "Loading…"
                    is ScreenState.Ready -> currentState.harnesses.size.toString()
                    is ScreenState.Failed -> "error"
                },
            )
        },
        containerColor = PapercupColors.Ink,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(PapercupColors.ScreenGradient)
                .padding(padding)
                .padding(horizontal = 16.dp),
        ) {
            when (val s = state) {
                ScreenState.Loading -> {
                    Row(
                        Modifier.fillMaxWidth().padding(top = 32.dp),
                        horizontalArrangement = Arrangement.Center,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        CircularProgressIndicator(strokeWidth = 2.dp)
                        Spacer(Modifier.width(12.dp))
                        Text(stringResource(R.string.loading_harnesses))
                    }
                }
                is ScreenState.Failed -> {
                    PapercupCard(accent = PapercupColors.ErrorSoft) {
                        Column {
                            Text(
                                "Couldn't load harnesses",
                                style = MaterialTheme.typography.titleMedium,
                                color = PapercupColors.Error,
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                s.message,
                                style = MaterialTheme.typography.bodySmall,
                                color = PapercupColors.Error,
                                fontFamily = FontFamily.Monospace,
                            )
                        }
                    }
                }
                is ScreenState.Ready -> {
                    PapercupCard(contentPadding = PaddingValues(12.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column {
                                PapercupCardHeader(
                                    title = "${s.harnesses.size} ${if (s.harnesses.size == 1) "harness" else "harnesses"}",
                                    meta = "core ${version()}",
                                )
                            }
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                PauseButton(creds = creds, liveTick = liveTick)
                                creds.meshAssignedIp?.let { ip ->
                                    MeshButton(creds = creds, ip = ip)
                                }
                                PapercupStatusChip(
                                    text = lastInvalidate?.let { "live · $it" } ?: "live",
                                    containerColor = PapercupColors.InfoSoft,
                                    contentColor = PapercupColors.Info,
                                )
                            }
                        }
                    }
                    LazyColumn(
                        contentPadding = PaddingValues(bottom = 96.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        items(s.harnesses) { harness ->
                            HarnessRow(harness, onClick = { onSelect(harness.slug) })
                        }
                    }
                }
            }
        }
    }
}

private data class VoiceFabStyle(
    val glyph: String,
    val label: String,
    val container: Color,
    val content: Color,
)

/// Banner stacked under the topBar that surfaces a Failed voice
/// state with a kind-specific action. Wire-format mirrors what the
/// server returns so each error has a distinct UX:
///   - MicPermission     → Open Settings
///   - QuotaExceeded     → Open Voice Settings (Settings → Voice)
///   - ConcurrentLimit   → Pre-empt (re-issues mint with force flag)
///   - MintCooldown      → countdown — no manual action available
///   - NetworkUnreachable→ Retry
///   - IdleTimeout       → Tap voice FAB (already shown there)
///   - SessionMax        → Tap voice FAB
///   - AgentEnded        → quiet auto-dismiss after 2s
///   - Unknown           → generic Retry + Dismiss
@Composable
private fun VoiceErrorBanner(
    failed: VoiceManager.State.Failed,
    onDismiss: () -> Unit,
    onRetry: () -> Unit,
) {
    val context = LocalContext.current
    // Auto-dismiss for benign "the session ended cleanly" kinds.
    LaunchedEffect(failed.kind) {
        if (failed.kind == VoiceManager.FailureKind.AgentEnded) {
            kotlinx.coroutines.delay(2_000)
            onDismiss()
        }
    }
    // Countdown for cooldown kinds — restart automatically when ready.
    val secondsRemaining = remember(failed.retryAfterSec) {
        mutableStateOf(failed.retryAfterSec ?: 0)
    }
    LaunchedEffect(failed.retryAfterSec) {
        if (failed.kind != VoiceManager.FailureKind.MintCooldown) return@LaunchedEffect
        var s = failed.retryAfterSec ?: 0
        while (s > 0) {
            kotlinx.coroutines.delay(1_000)
            s -= 1
            secondsRemaining.value = s
        }
    }
    val displayMessage = when (failed.kind) {
        VoiceManager.FailureKind.MintCooldown ->
            if (secondsRemaining.value > 0)
                "Cooling down — retry in ${secondsRemaining.value}s."
            else "Cooldown cleared — tap to retry."
        else -> failed.message
    }
    val accent = when (failed.kind) {
        VoiceManager.FailureKind.AgentEnded,
        VoiceManager.FailureKind.IdleTimeout,
        VoiceManager.FailureKind.SessionMax,
        VoiceManager.FailureKind.MintCooldown -> PapercupColors.AccentSoft
        else -> PapercupColors.ErrorSoft
    }
    Surface(
        color = accent,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 8.dp),
        ) {
            Text(
                displayMessage,
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.bodySmall,
                color = PapercupColors.Text,
            )
            // Kind-specific primary action.
            when (failed.kind) {
                VoiceManager.FailureKind.MicPermission -> {
                    TextButton(onClick = {
                        val intent = android.content.Intent(
                            android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            android.net.Uri.fromParts("package", context.packageName, null),
                        )
                        intent.flags = android.content.Intent.FLAG_ACTIVITY_NEW_TASK
                        context.startActivity(intent)
                    }) { Text("Settings") }
                }
                VoiceManager.FailureKind.QuotaExceeded -> {
                    // Soft link — the Voice Settings screen already
                    // shows the EL subscription / spend status. The
                    // user can drill in there.
                    TextButton(onClick = onDismiss) { Text("Dismiss") }
                }
                VoiceManager.FailureKind.ConcurrentLimit -> {
                    TextButton(onClick = onRetry) { Text("Pre-empt") }
                }
                VoiceManager.FailureKind.MintCooldown -> {
                    // Auto-resumes; manual dismiss only.
                    if (secondsRemaining.value <= 0) {
                        TextButton(onClick = onRetry) { Text("Retry") }
                    } else {
                        TextButton(onClick = onDismiss) { Text("Cancel") }
                    }
                }
                VoiceManager.FailureKind.NetworkUnreachable -> {
                    TextButton(onClick = onRetry) { Text("Retry") }
                }
                VoiceManager.FailureKind.IdleTimeout,
                VoiceManager.FailureKind.SessionMax -> {
                    TextButton(onClick = onRetry) { Text("Resume") }
                }
                VoiceManager.FailureKind.AgentEnded -> {
                    // No button — auto-dismisses via LaunchedEffect.
                }
                VoiceManager.FailureKind.Unknown -> {
                    TextButton(onClick = onRetry) { Text("Retry") }
                }
            }
            TextButton(onClick = onDismiss) { Text("×") }
        }
    }
}

@Composable
private fun VoiceFab(voice: VoiceManager) {
    val state by voice.state.collectAsState()
    val micLevel by voice.micLevel.collectAsState()
    val context = LocalContext.current
    var pendingStart by remember { mutableStateOf(false) }

    val micLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted && pendingStart) voice.start()
        pendingStart = false
    }

    val current = state
    val (glyph, label, container, content) = when (current) {
        is VoiceManager.State.Idle -> VoiceFabStyle("◉", "Listen", PapercupColors.InkRaised, PapercupColors.AccentStrong)
        is VoiceManager.State.Connecting -> VoiceFabStyle("⋯", "Connecting", PapercupColors.InkRaised, PapercupColors.Warning)
        is VoiceManager.State.Listening -> VoiceFabStyle("◼", "Listening", PapercupColors.Accent, PapercupColors.ButtonInk)
        is VoiceManager.State.Speaking -> VoiceFabStyle("◼", "Speaking", PapercupColors.AccentStrong, PapercupColors.ButtonInk)
        is VoiceManager.State.Failed -> VoiceFabStyle("!", "Error", PapercupColors.Error, Color.White)
    }

    val isListening = current is VoiceManager.State.Listening
    val animatedLevel by animateFloatAsState(
        targetValue = if (isListening) micLevel else 0f,
        animationSpec = tween(durationMillis = 120),
        label = "mic-level",
    )

    val onTap: () -> Unit = {
        if (current is VoiceManager.State.Idle || current is VoiceManager.State.Failed) {
            if (ContextCompat.checkSelfPermission(context, android.Manifest.permission.RECORD_AUDIO)
                == android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                voice.start()
            } else {
                pendingStart = true
                micLauncher.launch(android.Manifest.permission.RECORD_AUDIO)
            }
        } else {
            voice.stop()
        }
    }

    Box(contentAlignment = Alignment.Center) {
        // Mic-amplitude halo behind the FAB. Radius + alpha scale with
        // the normalised rms reported by SpeechRecognizer.onRmsChanged.
        // Invisible at idle/silent.
        if (animatedLevel > 0.01f) {
            Box(
                modifier = Modifier
                    .size((72 + (animatedLevel * 56)).dp)
                    .clip(RoundedCornerShape(999.dp))
                    .background(
                        content.copy(alpha = 0.10f + 0.20f * animatedLevel),
                    ),
            )
        }
        val voiceDescription = "Voice: $label" +
            if (current is VoiceManager.State.Idle || current is VoiceManager.State.Failed) "" else " (tap to stop)"
        Surface(
            modifier = Modifier
                .size(width = 80.dp, height = 56.dp)
                .border(1.dp, content.copy(alpha = 0.48f), RoundedCornerShape(999.dp))
                .clip(RoundedCornerShape(999.dp))
                .clickable(onClick = onTap)
                .semantics {
                    contentDescription = voiceDescription
                    role = androidx.compose.ui.semantics.Role.Button
                },
            shape = RoundedCornerShape(999.dp),
            color = container,
            contentColor = content,
        ) {
            Column(
                modifier = Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Text(glyph, style = MaterialTheme.typography.titleMedium)
                Text(label.uppercase(), style = MaterialTheme.typography.labelSmall)
            }
        }
    }
}

@Composable
private fun PauseButton(creds: DeviceCredentials, liveTick: Int) {
    var paused by remember { mutableStateOf<Boolean?>(null) }
    var inflight by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(creds.deviceToken, liveTick) {
        try {
            paused = creds.client().pauseGet().paused
        } catch (_: Throwable) { /* keep last-known state */ }
    }

    val (containerColor, contentColor) = if (paused == true) {
        PapercupColors.WarningSoft to PapercupColors.Warning
    } else {
        PapercupColors.SuccessSoft to PapercupColors.Success
    }
    PapercupStatusChip(
        text = when (paused) {
            true -> "paused"
            false -> "running"
            null -> "…"
        },
        onClick = {
            if (inflight) return@PapercupStatusChip
            val target = !(paused ?: false)
            inflight = true
            scope.launch {
                try {
                    paused = creds.client().pauseSet(target)
                } catch (_: Throwable) {
                } finally {
                    inflight = false
                }
            }
        },
        containerColor = containerColor,
        contentColor = contentColor,
    )
}

@Composable
private fun MeshButton(creds: DeviceCredentials, ip: String) {
    val context = LocalContext.current
    val tunnelState by MeshState.state.collectAsState()
    var pendingActivate by remember { mutableStateOf(false) }

    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (pendingActivate && result.resultCode == android.app.Activity.RESULT_OK) {
            creds.wgQuickConfig?.let { MeshController.activate(context, it) }
        }
        pendingActivate = false
    }

    val isUp = tunnelState == com.wireguard.android.backend.Tunnel.State.UP
    val isToggling = tunnelState == com.wireguard.android.backend.Tunnel.State.TOGGLE

    val (label, containerColor, contentColor) = when {
        isUp -> Triple("mesh ✓ $ip", PapercupColors.SuccessSoft, PapercupColors.Success)
        isToggling -> Triple("mesh ⟳ $ip", PapercupColors.WarningSoft, PapercupColors.Warning)
        else -> Triple("mesh · $ip", PapercupColors.AccentSoft, PapercupColors.AccentStrong)
    }
    PapercupStatusChip(
        text = label,
        onClick = {
            val cfg = creds.wgQuickConfig ?: return@PapercupStatusChip
            if (isUp) {
                MeshController.deactivate(context)
            } else {
                val prepare = MeshController.prepareIntent(context)
                if (prepare != null) {
                    pendingActivate = true
                    launcher.launch(prepare)
                } else {
                    MeshController.activate(context, cfg)
                }
            }
        },
        containerColor = containerColor,
        contentColor = contentColor,
    )
}

@Composable
private fun HarnessRow(harness: Harness, onClick: () -> Unit) {
    val statusText = harness.status?.let { "status $it" } ?: "no status"
    PapercupCard(
        modifier = Modifier
            .clickable(onClick = onClick)
            .semantics(mergeDescendants = true) {
                contentDescription = "Harness ${harness.slug}, $statusText. Double-tap to open."
                role = androidx.compose.ui.semantics.Role.Button
            },
        contentPadding = PaddingValues(12.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(harness.slug, style = MaterialTheme.typography.titleMedium)
                harness.status?.let { status ->
                    PapercupStatusChip(text = status)
                }
            }
            harness.path.takeIf { it.isNotBlank() }?.let {
                PapercupMetaText(it, monospace = true)
            }
            val meta = buildList {
                harness.harnessKind?.let { add("kind=$it") }
                harness.iteration?.let { add("iter=$it") }
                if (!harness.hasState) add("no-state")
            }.joinToString(" · ")
            if (meta.isNotEmpty()) {
                PapercupMetaText(meta)
            }
        }
    }
}

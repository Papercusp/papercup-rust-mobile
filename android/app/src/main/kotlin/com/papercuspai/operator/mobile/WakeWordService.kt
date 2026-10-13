// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/// Phase 5 — foreground service that hosts the Picovoice Porcupine
/// wake-word engine so "hey papercup" listens while the app is
/// backgrounded or the screen's off.
///
/// Lifecycle:
///   - WakeWordService.start(context) brings it up + binds to the
///     existing WakeWordEngine
///   - WakeWordService.stop(context) tears it down
///   - On detection, broadcasts ACTION_WAKE which MainActivity
///     receives + uses to start the VoiceManager
///
/// foregroundServiceType=microphone — Porcupine opens a continuous
/// AudioRecord stream internally; Play Store + Android 14+ runtime
/// require `microphone` (not specialUse) for any FGS that captures
/// audio. The matching FOREGROUND_SERVICE_MICROPHONE permission is
/// declared in AndroidManifest.xml. Without it, startForeground()
/// throws SecurityException on API 34+.
class WakeWordService : Service() {

    private var engine: WakeWordEngine? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        // The Service manifest declares foregroundServiceType="microphone".
        // Starting FGS-microphone on API 34+ requires RECORD_AUDIO at the
        // moment of startForeground(); and downgrading at runtime to type
        // NONE is prohibited because of the manifest declaration. So if
        // either Picovoice key OR RECORD_AUDIO is missing, the safe move
        // is to refuse the start — but we MUST still call startForeground
        // within 10s OR the FGS-did-not-start-in-time exception kills the
        // whole app. We do go FGS-microphone (matching manifest), then
        // stopSelf — startForeground crashes if RECORD_AUDIO missing, so
        // gate caller-side as well (see MainActivity).
        val hasRecordAudio = androidx.core.content.ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.RECORD_AUDIO,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        val keyword = WakeWordEngine.configuredKeyword(applicationContext)
        if (keyword == null || !hasRecordAudio) {
            Log.i(TAG, "wake word inert — key=${WakeWordEngine.isConfigured()} rec=$hasRecordAudio; faking FGS to satisfy ANR contract then stopping")
            // Fallback: declare-only. Without RECORD_AUDIO we can't go
            // FGS-microphone; the only way to avoid the timer-fired
            // ForegroundServiceDidNotStartInTimeException is to satisfy
            // the contract with the same microphone type and accept the
            // SecurityException, OR never have been started. We choose
            // the latter — MainActivity must gate this. If we get here,
            // we're already in an unrecoverable state, but stopSelf is
            // the least-bad option.
            stopSelf()
            return
        }
        ensureChannel(applicationContext)
        startForegroundCompat(keyword)
        engine = WakeWordEngine(applicationContext) {
            Log.i(TAG, "wake word fired — broadcasting ACTION_WAKE")
            sendBroadcast(Intent(ACTION_WAKE).setPackage(packageName))
        }
        if (engine?.start() != true) stopSelf()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // NOT_STICKY: if the OS kills us we don't want auto-restart loops.
        // The Composable's DisposableEffect re-starts us next remount
        // when the caller-side gate passes.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        engine?.stop()
        engine = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    private fun startForegroundCompat(keyword: String) {
        val notif: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle(getString(R.string.wake_word_notification_title))
            .setContentText(getString(R.string.wake_word_notification_text, keyword))
            .setOngoing(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    companion object {
        const val ACTION_WAKE = "com.papercuspai.operator.mobile.WAKE"
        private const val TAG = "PapercupWakeSvc"
        private const val CHANNEL_ID = "papercup-wakeword"
        private const val NOTIF_ID = 4242

        fun start(context: Context) {
            ensureChannel(context)
            val intent = Intent(context, WakeWordService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, WakeWordService::class.java))
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.wake_word_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = context.getString(R.string.wake_word_channel_description)
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }
    }
}

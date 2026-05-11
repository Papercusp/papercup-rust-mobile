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
        ensureChannel(applicationContext)
        startForegroundCompat()
        engine = WakeWordEngine(applicationContext) {
            Log.i(TAG, "wake word fired — broadcasting ACTION_WAKE")
            sendBroadcast(Intent(ACTION_WAKE).setPackage(packageName))
        }
        engine?.start()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
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

    private fun startForegroundCompat() {
        val notif: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle(getString(R.string.wake_word_notification_title))
            .setContentText(getString(R.string.wake_word_notification_text))
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

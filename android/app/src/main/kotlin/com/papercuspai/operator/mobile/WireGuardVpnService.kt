package com.papercuspai.operator.mobile

// SPDX-License-Identifier: GPL-3.0-or-later
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.Tunnel
import com.wireguard.config.Config
import java.io.ByteArrayInputStream

class WireGuardVpnService : VpnService() {

    private var backend: GoBackend? = null
    private var tunnel: Tunnel? = null

    companion object {
        const val TAG = "PapercupMesh"
        const val EXTRA_WG_CONFIG = "wg-config"
        const val ACTION_STOP = "com.papercuspai.operator.mobile.MESH_STOP"
        const val NOTIFICATION_ID = 4242
        const val CHANNEL_ID = "papercup-mesh"
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        val configString = intent?.getStringExtra(EXTRA_WG_CONFIG)
        if (configString == null) {
            Log.w(TAG, "no wg-config in intent; stopping")
            stopSelf()
            return START_NOT_STICKY
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                buildNotification("Papercup mesh: connecting…"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, buildNotification("Papercup mesh: connecting…"))
        }

        Thread {
            try {
                val config = Config.parse(ByteArrayInputStream(configString.toByteArray()))
                backend = GoBackend(applicationContext)
                val t = object : Tunnel {
                    override fun getName() = "papercup-mesh"
                    override fun onStateChange(newState: Tunnel.State) {
                        Log.i(TAG, "tunnel state -> $newState")
                    }
                }
                tunnel = t
                backend!!.setState(t, Tunnel.State.UP, config)
                updateNotification("Papercup mesh: connected")
            } catch (e: Exception) {
                Log.e(TAG, "tunnel start failed", e)
                stopSelf()
            }
        }.start()

        return START_STICKY
    }

    override fun onDestroy() {
        try {
            tunnel?.let { backend?.setState(it, Tunnel.State.DOWN, null) }
        } catch (_: Exception) {}
        backend = null
        tunnel = null
        super.onDestroy()
    }

    private fun buildNotification(text: String): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Papercup mesh", NotificationManager.IMPORTANCE_LOW)
                )
            }
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setOngoing(true)
            .setContentTitle("Papercup mesh")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .build()
    }

    private fun updateNotification(text: String) {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification(text))
    }
}

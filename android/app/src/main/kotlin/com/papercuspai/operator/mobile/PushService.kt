// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import uniffi.papercup.OperatorClient

/// Receives FCM tokens + delivered messages.
///
/// Push payload contract (proposed; coord/mobile.jsonl asks backend to
/// confirm). FCM `data` keys, all optional except where noted:
///
///   type     := "harness" | "checkpoint" | "smoke" | "generic"  (req)
///   title    := short notification title                         (req)
///   body     := body text                                        (req)
///   slug     := harness slug — when present, tapping deep-links into
///               the harness detail screen
///   eventId  := opaque id for dedup; falls back to the FCM message id
///
/// `notification` field on the FCM envelope is also honored when `data`
/// is absent, but `data` is the preferred shape because it carries the
/// payload through to onMessageReceived even when the app is in the
/// background.
class PushService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        Log.i(TAG, "fcm token rotated; registering")
        val store = CredentialStore(applicationContext)
        val creds = store.load() ?: return
        CoroutineScope(Dispatchers.IO).launch {
            try {
                OperatorClient(creds.server, creds.deviceToken)
                    .registerPush(platform = "fcm", token = token)
            } catch (t: Throwable) {
                Log.w(TAG, "registerPush failed: ${t.message}")
            }
        }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        Log.i(TAG, "fcm message: data=${message.data} notif=${message.notification?.title}")
        val data = message.data

        // Data-only invalidation payload — no title/body, just an
        // `invalidate` key with the sync name to refetch. Plumb it
        // through the existing OperatorClient (best-effort; FCM gives
        // us up to ~10s of background CPU which is enough to refetch).
        val invalidate = data["invalidate"]
        if (invalidate != null && data["title"] == null) {
            Log.i(TAG, "fcm data-only invalidate: $invalidate")
            handleInvalidate(invalidate)
            return
        }

        val title = data["title"] ?: message.notification?.title ?: "Papercup"
        val body = data["body"] ?: message.notification?.body ?: return
        val slug = data["slug"]
        val eventId = data["eventId"] ?: message.messageId
        showNotification(applicationContext, title, body, slug, eventId)
    }

    /// Best-effort: poke a refresh on the named query. The full sync
    /// cache landed in phase 11h (papercup-core::cache); for now we
    /// just bump heartbeat so the desktop knows we're connected and
    /// log the invalidation so it shows in adb logcat for triage.
    private fun handleInvalidate(name: String) {
        val store = CredentialStore(applicationContext)
        val creds = store.load() ?: return
        CoroutineScope(Dispatchers.IO).launch {
            try {
                OperatorClient(creds.server, creds.deviceToken).heartbeat()
                Log.i(TAG, "fcm invalidate refetch ack for $name")
            } catch (t: Throwable) {
                Log.w(TAG, "fcm invalidate refetch failed: ${t.message}")
            }
        }
    }

    private companion object {
        const val TAG = "PapercupPush"
    }
}

/// Shared notification helpers — kept in one file to keep the channel
/// constants in lockstep with the receiver.
const val PUSH_CHANNEL_ID = "papercup-pushes"
const val EXTRA_DEEPLINK_SLUG = "papercup.deeplink.slug"

fun ensureNotificationChannel(context: Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val nm = ContextCompat.getSystemService(context, NotificationManager::class.java) ?: return
    if (nm.getNotificationChannel(PUSH_CHANNEL_ID) != null) return
    val channel = NotificationChannel(
        PUSH_CHANNEL_ID,
        "Papercup updates",
        NotificationManager.IMPORTANCE_DEFAULT,
    ).apply { description = "Push notifications from your paired desktop." }
    nm.createNotificationChannel(channel)
}

fun showNotification(
    context: Context,
    title: String,
    body: String,
    slug: String?,
    eventId: String?,
) {
    ensureNotificationChannel(context)
    val launch = Intent(context, MainActivity::class.java).apply {
        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        if (slug != null) putExtra(EXTRA_DEEPLINK_SLUG, slug)
    }
    val pi = PendingIntent.getActivity(
        context,
        (eventId?.hashCode() ?: 0),
        launch,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
    val notif = NotificationCompat.Builder(context, PUSH_CHANNEL_ID)
        .setContentTitle(title)
        .setContentText(body)
        .setSmallIcon(android.R.drawable.stat_notify_sync)
        .setAutoCancel(true)
        .setContentIntent(pi)
        .build()
    val nm = ContextCompat.getSystemService(context, NotificationManager::class.java) ?: return
    nm.notify(eventId?.hashCode() ?: System.currentTimeMillis().toInt(), notif)
}

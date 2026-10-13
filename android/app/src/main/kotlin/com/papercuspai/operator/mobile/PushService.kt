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
import java.util.concurrent.atomic.AtomicInteger

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
                creds.client()
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

        val title = data["title"] ?: message.notification?.title ?: "Papercusp"
        val body = data["body"] ?: message.notification?.body ?: return
        // The attention-notify backend sends `harness` (not `slug`) + a `kind`
        // (intervention/smoke-fail/plan-review/needs-human). A harness deep-links
        // to its detail; any attention push without a harness opens the Inbox —
        // the actionable feed it belongs to (mobile-apps-revival-redesign D-004).
        val slug = data["slug"] ?: data["harness"]
        val toInbox = data["kind"] != null
        val eventId = data["eventId"] ?: data["plan"] ?: message.messageId
        showNotification(applicationContext, title, body, slug, toInbox, eventId, data["kind"])
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
                creds.client().heartbeat()
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
const val EXTRA_DEEPLINK_INBOX = "papercup.deeplink.inbox"
const val EXTRA_DEEPLINK_KIND = "papercup.deeplink.kind"
private val anonymousNotificationIds = AtomicInteger(System.currentTimeMillis().toInt())

fun ensureNotificationChannel(context: Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val nm = ContextCompat.getSystemService(context, NotificationManager::class.java) ?: return
    if (nm.getNotificationChannel(PUSH_CHANNEL_ID) != null) return
    val channel = NotificationChannel(
        PUSH_CHANNEL_ID,
        context.getString(R.string.push_channel_name),
        NotificationManager.IMPORTANCE_DEFAULT,
    ).apply { description = context.getString(R.string.push_channel_description) }
    nm.createNotificationChannel(channel)
}

fun showNotification(
    context: Context,
    title: String,
    body: String,
    slug: String?,
    toInbox: Boolean,
    eventId: String?,
    kind: String? = null,
) {
    ensureNotificationChannel(context)
    // The drawer entry and its PendingIntent must share one identity. Otherwise
    // FLAG_UPDATE_CURRENT replaces every anonymous notification's tap extras.
    val notificationId = eventId?.hashCode() ?: anonymousNotificationIds.incrementAndGet()
    val launch = Intent(context, MainActivity::class.java).apply {
        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        if (slug != null) putExtra(EXTRA_DEEPLINK_SLUG, slug)
        if (toInbox) putExtra(EXTRA_DEEPLINK_INBOX, true)
        if (kind != null) putExtra(EXTRA_DEEPLINK_KIND, kind)
    }
    val pi = PendingIntent.getActivity(
        context,
        notificationId,
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
    nm.notify(notificationId, notif)
}

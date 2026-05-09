// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import uniffi.papercup.OperatorClient

/// Receives FCM token rotations + delivered messages. The token is
/// pushed back to the operator via /api/mobile/push/register so the
/// desktop can target this device.
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
        // Phase 5b will turn these into Android notifications. For now,
        // surface to logcat so we can verify delivery end-to-end.
        Log.i(TAG, "fcm message: data=${message.data} notif=${message.notification?.title}")
    }

    private companion object {
        const val TAG = "PapercupPush"
    }
}

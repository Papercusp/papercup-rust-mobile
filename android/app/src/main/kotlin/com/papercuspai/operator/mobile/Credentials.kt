// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

data class DeviceCredentials(
    val server: String,
    val deviceToken: String,
    val deviceId: String,
    val workspaceId: String,
)

/// Keystore-backed credential store. Persists the JWT + paired desktop URL
/// returned by `OperatorClient.pair()` so the app boots straight to the
/// harness list on subsequent launches.
class CredentialStore(context: Context) {
    private val prefs: SharedPreferences =
        EncryptedSharedPreferences.create(
            context.applicationContext,
            "papercup-credentials",
            MasterKey.Builder(context.applicationContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )

    fun load(): DeviceCredentials? {
        val server = prefs.getString(KEY_SERVER, null) ?: return null
        val token = prefs.getString(KEY_TOKEN, null) ?: return null
        val deviceId = prefs.getString(KEY_DEVICE_ID, null) ?: return null
        val workspaceId = prefs.getString(KEY_WORKSPACE_ID, null) ?: return null
        return DeviceCredentials(server, token, deviceId, workspaceId)
    }

    fun save(creds: DeviceCredentials) {
        prefs.edit()
            .putString(KEY_SERVER, creds.server)
            .putString(KEY_TOKEN, creds.deviceToken)
            .putString(KEY_DEVICE_ID, creds.deviceId)
            .putString(KEY_WORKSPACE_ID, creds.workspaceId)
            .apply()
    }

    fun clear() {
        prefs.edit().clear().apply()
    }

    private companion object {
        const val KEY_SERVER = "server"
        const val KEY_TOKEN = "device_token"
        const val KEY_DEVICE_ID = "device_id"
        const val KEY_WORKSPACE_ID = "workspace_id"
    }
}

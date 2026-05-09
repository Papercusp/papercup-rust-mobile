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
    /// Phase 6a: present when the desktop's pair response carried a Defguard
    /// mesh config. Display only for now; Phase 6b will use it to bring up
    /// the WireGuard tunnel.
    val meshAssignedIp: String? = null,
    /// Phase 6b: full wg-quick INI ready for `Config.parse()` once the
    /// WireGuardVpnService is wired in. Generated locally on pair from
    /// the device's private key + the broker-assigned MeshConfig.
    val wgQuickConfig: String? = null,
    /// Phase 6b: device's WireGuard private key, base64. Persisted in
    /// the same Keystore-backed prefs as the JWT.
    val wgPrivateKey: String? = null,
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
        return DeviceCredentials(
            server = server,
            deviceToken = token,
            deviceId = deviceId,
            workspaceId = workspaceId,
            meshAssignedIp = prefs.getString(KEY_MESH_IP, null),
            wgQuickConfig = prefs.getString(KEY_WG_QUICK, null),
            wgPrivateKey = prefs.getString(KEY_WG_PRIV, null),
        )
    }

    fun save(creds: DeviceCredentials) {
        prefs.edit()
            .putString(KEY_SERVER, creds.server)
            .putString(KEY_TOKEN, creds.deviceToken)
            .putString(KEY_DEVICE_ID, creds.deviceId)
            .putString(KEY_WORKSPACE_ID, creds.workspaceId)
            .putString(KEY_MESH_IP, creds.meshAssignedIp)
            .putString(KEY_WG_QUICK, creds.wgQuickConfig)
            .putString(KEY_WG_PRIV, creds.wgPrivateKey)
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
        const val KEY_MESH_IP = "mesh_assigned_ip"
        const val KEY_WG_QUICK = "wg_quick_config"
        const val KEY_WG_PRIV = "wg_private_key"
    }
}

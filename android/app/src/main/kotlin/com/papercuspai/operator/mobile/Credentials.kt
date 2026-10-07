// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import uniffi.papercup.ApiException
import uniffi.papercup.OperatorClient
import uniffi.papercup.WorkspaceSwitchResult

data class DeviceCredentials(
    val server: String,
    val deviceToken: String,
    val deviceId: String,
    val workspaceId: String,
    /// Mesh URL the OperatorClient prefers when reachable (e.g.
    /// http://10.10.0.2:3070), with auto-fallback to the public `server`
    /// on transport error (OperatorClient.newWithFallback). Populated from
    /// the desktop's runtime-config mesh_host once the device joins the
    /// Defguard mesh; null until then (public/LAN reachability still works).
    val meshUrl: String? = null,
    /// Defguard self-enrollment URL from the pair outcome (D-005). The
    /// device opens this once to join the mesh; display-only afterward.
    val defguardEnrollmentUrl: String? = null,
    /// Phone identity and QR machine pin, stored with the JWT in encrypted prefs.
    val noiseSeed: String? = null,
    val noiseKey: String? = null,
) {
    // Data-class diagnostics must not expose the newly persisted private seed.
    override fun toString(): String =
        "DeviceCredentials(deviceId=$deviceId, workspaceId=$workspaceId, sealed=${noiseKey != null})"

    /// Build an OperatorClient that prefers the mesh URL (if known) and
    /// auto-falls back to the public `server` URL on transport failure.
    /// Use this everywhere instead of OperatorClient(_, _).
    fun client(): OperatorClient {
        val mesh = meshUrl
        val client = if (!mesh.isNullOrBlank() && mesh != server) {
            OperatorClient.newWithFallback(mesh, server, deviceToken)
        } else {
            OperatorClient(server, deviceToken)
        }
        if (noiseSeed != null || noiseKey != null) {
            if (noiseSeed == null || noiseKey == null) {
                throw ApiException.Decode("Incomplete sealed pairing; pair again")
            }
            client.configureSealedTransport(noiseSeed, noiseKey)
        }
        return client
    }

    suspend fun switchWorkspace(
        workspaceId: String,
        request: suspend (String) -> WorkspaceSwitchResult,
        onSwitched: (DeviceCredentials) -> Unit,
    ): DeviceCredentials {
        val response = request(workspaceId)
        if (response.workspaceId != workspaceId || response.deviceToken.isBlank()) {
            throw ApiException.Decode("Workspace switch returned an invalid token or workspace")
        }
        val fresh = copy(deviceToken = response.deviceToken, workspaceId = response.workspaceId)
        onSwitched(fresh)
        return fresh
    }
}

/// Keystore-backed credential store. Persists the JWT + paired desktop URL
/// returned by `OperatorClient.pair()` so the app boots straight to the
/// Inbox on subsequent launches.
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
        val seed = prefs.getString(KEY_NOISE_SEED, null)
        val key = prefs.getString(KEY_NOISE_KEY, null)
        // A partial identity must never restore as an unsealed session.
        if ((seed == null) != (key == null)) return null
        return DeviceCredentials(
            server = server,
            deviceToken = token,
            deviceId = deviceId,
            workspaceId = workspaceId,
            meshUrl = prefs.getString(KEY_MESH_URL, null),
            defguardEnrollmentUrl = prefs.getString(KEY_DEFGUARD_URL, null),
            noiseSeed = seed,
            noiseKey = key,
        )
    }

    fun save(creds: DeviceCredentials) {
        prefs.edit()
            .putString(KEY_SERVER, creds.server)
            .putString(KEY_TOKEN, creds.deviceToken)
            .putString(KEY_DEVICE_ID, creds.deviceId)
            .putString(KEY_WORKSPACE_ID, creds.workspaceId)
            .putString(KEY_MESH_URL, creds.meshUrl)
            .putString(KEY_DEFGUARD_URL, creds.defguardEnrollmentUrl)
            .putString(KEY_NOISE_SEED, creds.noiseSeed)
            .putString(KEY_NOISE_KEY, creds.noiseKey)
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
        const val KEY_MESH_URL = "mesh_url"
        const val KEY_DEFGUARD_URL = "defguard_enrollment_url"
        const val KEY_NOISE_SEED = "noise_seed"
        const val KEY_NOISE_KEY = "noise_key"
    }
}

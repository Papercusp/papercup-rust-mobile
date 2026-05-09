// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.content.Context
import android.content.Intent
import android.net.VpnService
import androidx.core.content.ContextCompat

/// Thin wrapper around `WireGuardVpnService` that the UI calls to
/// activate / deactivate the mesh. Returning a non-null Intent from
/// `prepare()` means the user must approve the VPN once via system
/// dialog — surface that intent through an ActivityResult contract.
object MeshController {
    fun prepareIntent(context: Context): Intent? = VpnService.prepare(context)

    fun activate(context: Context, wgQuick: String) {
        val intent = Intent(context, WireGuardVpnService::class.java).apply {
            putExtra(WireGuardVpnService.EXTRA_WG_CONFIG, wgQuick)
        }
        ContextCompat.startForegroundService(context, intent)
    }

    fun deactivate(context: Context) {
        val intent = Intent(context, WireGuardVpnService::class.java).apply {
            action = WireGuardVpnService.ACTION_STOP
        }
        ContextCompat.startForegroundService(context, intent)
    }
}

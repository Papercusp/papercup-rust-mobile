// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import com.wireguard.android.backend.Tunnel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/// Shared, app-process state for the mesh tunnel. The
/// `WireGuardVpnService` writes here on `Tunnel.onStateChange`; the
/// UI reads it via `collectAsState` so the chip mirrors the real
/// tunnel state rather than a UI-local "did we tap" boolean.
object MeshState {
    private val _state = MutableStateFlow<Tunnel.State>(Tunnel.State.DOWN)
    val state: StateFlow<Tunnel.State> = _state.asStateFlow()

    fun set(newState: Tunnel.State) {
        _state.value = newState
    }
}

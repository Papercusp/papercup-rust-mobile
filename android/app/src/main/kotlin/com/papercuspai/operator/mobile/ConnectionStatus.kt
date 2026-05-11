// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import uniffi.papercup.OperatorClient

enum class ConnStatus { Unknown, Online, Offline }

data class ConnectionState(
    val status: ConnStatus = ConnStatus.Unknown,
    val offlineSinceMs: Long? = null,
    val lastPingMs: Int? = null,
)

class ConnectionMonitor(
    private val scope: CoroutineScope,
    private val creds: DeviceCredentials,
) {
    private val _state = MutableStateFlow(ConnectionState())
    val state: StateFlow<ConnectionState> = _state.asStateFlow()
    private var job: Job? = null

    fun start() {
        if (job != null) return
        job = scope.launch {
            while (true) {
                probe()
                delay(20_000)
            }
        }
    }

    fun stop() {
        job?.cancel()
        job = null
    }

    suspend fun probe() {
        val client = creds.client()
        val t0 = System.currentTimeMillis()
        try {
            client.heartbeat()
            val rt = (System.currentTimeMillis() - t0).toInt()
            _state.value = ConnectionState(ConnStatus.Online, null, rt)
        } catch (_: Throwable) {
            val prev = _state.value
            val since = if (prev.status == ConnStatus.Offline) prev.offlineSinceMs else System.currentTimeMillis()
            _state.value = ConnectionState(ConnStatus.Offline, since, null)
        }
    }
}

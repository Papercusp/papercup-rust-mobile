// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import java.net.URI

/** Release endpoint policy for pairing and all bearer-authenticated traffic. */
object EndpointSecurity {
    private val debugHosts = setOf("127.0.0.1", "localhost", "10.0.2.2")

    fun rejectionReason(rawUrl: String, allowDebugLoopback: Boolean): String? {
        val uri = runCatching { URI(rawUrl.trim()) }.getOrNull()
            ?: return "That pairing code has an invalid desktop address."
        val scheme = uri.scheme?.lowercase()
        val host = uri.host?.lowercase()
        if (scheme == "https" && !host.isNullOrBlank()) return null
        if (allowDebugLoopback && scheme == "http" && host in debugHosts) return null
        return "Papercusp requires a secure HTTPS desktop address. Show a new pairing code from an up-to-date desktop."
    }
}

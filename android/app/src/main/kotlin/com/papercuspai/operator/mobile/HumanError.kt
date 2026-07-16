// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import uniffi.papercup.ApiException
import uniffi.papercup.PairException

/**
 * WI-4966: one place that turns transport/API failures into copy a human can
 * act on. Before this, screens rendered raw UniFFI/reqwest text (e.g.
 * "API: Network: detail=error sending request for url (…)") straight into
 * error cards — user-incomprehensible and unrecoverable-in-app, graded
 * DEGRADED on the mobile-app-release-readiness rubric (error-recovery-ux,
 * scorecard EI-12506).
 *
 * Classification order: the TYPED ApiException variants first (lossless),
 * then well-known JVM transport exception types, then a conservative
 * message-text sniff. The raw detail never reaches the returned copy — it
 * belongs in logcat / the Diagnostics screen, which deliberately keep it.
 *
 * Pure JVM (no android.* imports) so unit tests pin the contract.
 */
object HumanError {
    /**
     * @param t the failure
     * @param what sentence-initial description of what was attempted,
     *   e.g. "Loading this harness" → "Loading this harness failed — …".
     */
    fun describe(t: Throwable, what: String): String = when (t) {
        is ApiException.Network -> fromNetworkText(t.detail, what)
        is ApiException.Server -> fromHttpStatus(t.status.toInt(), what)
        is ApiException.Unauthorized ->
            "$what failed — this device's pairing is no longer valid. " +
                "Re-pair with your Papercup server from Settings."
        is ApiException.Decode ->
            "$what failed — the server's response didn't match this app " +
                "version. Update the app (or the server), then retry."
        is PairException.Network -> fromNetworkText(t.detail, what)
        is PairException.Server -> fromHttpStatus(t.status.toInt(), what)
        is PairException.Decode ->
            "$what failed — the server's response didn't match this app " +
                "version. Update the app (or the server), then retry."
        is PairException.Unauthorized ->
            "$what failed — the pairing code was rejected. Pairing codes are " +
                "one-time: generate a fresh one on the desktop and try again."
        is PairException.InvalidQr ->
            "$what failed — that QR/pairing code isn't valid (it may have " +
                "expired or already been used). Generate a fresh one on the " +
                "desktop and scan again."
        is java.net.SocketTimeoutException -> timeoutCopy(what)
        is java.net.UnknownHostException, is java.net.ConnectException -> unreachableCopy(what)
        is javax.net.ssl.SSLException -> tlsCopy(what)
        else -> fromNetworkText(t.message ?: "", what)
    }

    /** For callsites that only have raw text (e.g. a UniFFI voice error string). */
    fun fromNetworkText(detail: String, what: String): String {
        val d = detail.lowercase()
        return when {
            listOf("timed out", "timeout", "deadline").any { d.contains(it) } -> timeoutCopy(what)
            listOf(
                "refused", "unreachable", "no route", "dns", "resolve",
                "error sending request", "unknownhost", "failed to connect",
                "connection reset", "broken pipe", "network is down",
            ).any { d.contains(it) } -> unreachableCopy(what)
            listOf("ssl", "tls", "certificate", "handshake").any { d.contains(it) } -> tlsCopy(what)
            Regex("\\bstatus[ =:]*4[013]\\d\\b").containsMatchIn(d) || d.contains("unauthorized") ->
                "$what failed — this device's pairing may no longer be valid. " +
                    "Retry once; if it keeps failing, re-pair from Settings."
            d.isBlank() ->
                "$what failed. Retry in a moment — if it keeps happening, " +
                    "check Settings → Diagnostics."
            else ->
                "$what failed — a network problem got in the way. Check that " +
                    "this phone is online and your Papercup server is running, then retry."
        }
    }

    private fun fromHttpStatus(status: Int, what: String): String = when {
        status == 429 ->
            "$what failed — the server is busy right now. Wait a few seconds and retry."
        status == 401 || status == 403 ->
            "$what failed — this device's pairing is no longer valid. " +
                "Re-pair with your Papercup server from Settings."
        status in 500..599 ->
            "$what failed — the server hit an internal error. Give it a moment, then retry."
        else ->
            "$what failed — the server rejected the request (HTTP $status). " +
                "Retry; if it keeps failing, re-pair from Settings."
    }

    private fun timeoutCopy(what: String) =
        "$what failed — the server took too long to respond. Retry in a moment."

    private fun unreachableCopy(what: String) =
        "$what failed — can't reach your Papercup server. Check that the " +
            "server is running and this phone is online, then retry."

    private fun tlsCopy(what: String) =
        "$what failed — the secure connection couldn't be established. " +
            "Check the server address, then retry."
}

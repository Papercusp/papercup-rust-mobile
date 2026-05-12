// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/// Rolling sample buffer for the Performance HUD on Settings → Voice.
/// We track first-word latency (time from `start()` until the first
/// `onAgentResponse`) and session-length distributions. The HUD shows
/// P50/P95 over the last `SAMPLE_CAP` sessions; raw samples persist
/// across app restarts so users can spot regressions between builds.
object VoiceMetrics {
    private const val PREF_NAME = "papercup-voice-metrics"
    private const val KEY_FIRST_WORD = "firstWordMs"
    private const val KEY_SESSION_LEN = "sessionLenMs"
    /// Keep the last N samples. 50 = enough for P50/P95 stability,
    /// small enough that the SharedPreferences write stays under
    /// a couple KB.
    private const val SAMPLE_CAP = 50

    data class Stats(val count: Int, val p50: Long, val p95: Long, val max: Long)

    /// Append a new first-word latency in milliseconds.
    fun recordFirstWordMs(context: Context, ms: Long) {
        if (ms < 0 || ms > 60_000) return // sanity
        appendSample(context, KEY_FIRST_WORD, ms)
    }

    /// Append a new session-length in milliseconds.
    fun recordSessionLenMs(context: Context, ms: Long) {
        if (ms < 0 || ms > 60 * 60_000L) return
        appendSample(context, KEY_SESSION_LEN, ms)
    }

    fun firstWordStats(context: Context): Stats =
        readStats(context, KEY_FIRST_WORD)

    fun sessionLenStats(context: Context): Stats =
        readStats(context, KEY_SESSION_LEN)

    /// Wipe all samples (Settings button).
    fun reset(context: Context) {
        context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit().clear().apply()
    }

    private fun appendSample(context: Context, key: String, ms: Long) {
        val sp = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
        val arr = readArr(sp, key)
        arr.put(ms)
        // Drop the oldest if we're past cap.
        while (arr.length() > SAMPLE_CAP) arr.remove(0)
        sp.edit().putString(key, arr.toString()).apply()
    }

    private fun readStats(context: Context, key: String): Stats {
        val sp = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
        val arr = readArr(sp, key)
        val n = arr.length()
        if (n == 0) return Stats(0, 0, 0, 0)
        val sorted = LongArray(n) { arr.optLong(it) }.also { it.sort() }
        fun pct(p: Double): Long {
            val idx = ((n - 1) * p).toInt().coerceIn(0, n - 1)
            return sorted[idx]
        }
        return Stats(n, pct(0.5), pct(0.95), sorted.last())
    }

    private fun readArr(sp: android.content.SharedPreferences, key: String): JSONArray {
        val raw = sp.getString(key, "[]") ?: "[]"
        return try { JSONArray(raw) } catch (_: Throwable) { JSONArray() }
    }
}

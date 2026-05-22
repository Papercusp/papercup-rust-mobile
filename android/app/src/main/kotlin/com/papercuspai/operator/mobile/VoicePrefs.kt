// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.content.Context

enum class VoiceMode(val wire: String) {
    Continuous("continuous"),
    Hybrid("hybrid"),
    SingleUtterance("single-utterance");

    companion object {
        fun fromWire(s: String?): VoiceMode = when (s) {
            "hybrid" -> Hybrid
            "single-utterance" -> SingleUtterance
            else -> Continuous
        }
    }
}

/// Device-local voice preferences. Distinct from the workspace-shared
/// prefs in operator_voice_prefs (PG) — these stay on the device and
/// get passed to /api/device/voice-session-init as query params so
/// the server can resolve mode-dependent behavior (idle timer floor
/// for single-utterance, voice_mode dynamic_variable for the agent
/// prompt, etc.) without overwriting another device's choice.
data class VoicePrefs(
    val wakeWord: String = "hey papercup",
    val rate: Float = 1.0f,
    val pitch: Float = 1.0f,
    val voiceName: String? = null,
    /** Conversation flow. Default continuous = ChatGPT-style. */
    val voiceMode: VoiceMode = VoiceMode.Continuous,
    /**
     * Idle minutes before auto-disconnect on user silence. 0 lets the
     * server's workspace default apply; otherwise overrides. The
     * server clamps to ≤1 when voiceMode == SingleUtterance regardless
     * of this value.
     */
    val idleTimeoutMin: Int = 0,
    /** Hard session ceiling. 0 = server's workspace default. */
    val sessionMaxMin: Int = 0,
)

class VoicePrefsStore(context: Context) {
    private val sp = context.getSharedPreferences("papercup-voice-prefs", Context.MODE_PRIVATE)

    fun load(): VoicePrefs = VoicePrefs(
        wakeWord = sp.getString("wakeWord", "hey papercup") ?: "hey papercup",
        rate = sp.getFloat("rate", 1.0f),
        pitch = sp.getFloat("pitch", 1.0f),
        voiceName = sp.getString("voiceName", null),
        voiceMode = VoiceMode.fromWire(sp.getString("voiceMode", null)),
        idleTimeoutMin = sp.getInt("idleTimeoutMin", 0),
        sessionMaxMin = sp.getInt("sessionMaxMin", 0),
    )

    fun save(p: VoicePrefs) {
        sp.edit()
            .putString("wakeWord", p.wakeWord)
            .putFloat("rate", p.rate)
            .putFloat("pitch", p.pitch)
            .putString("voiceMode", p.voiceMode.wire)
            .putInt("idleTimeoutMin", p.idleTimeoutMin)
            .putInt("sessionMaxMin", p.sessionMaxMin)
            .apply { if (p.voiceName == null) remove("voiceName") else putString("voiceName", p.voiceName) }
            .apply()
    }
}

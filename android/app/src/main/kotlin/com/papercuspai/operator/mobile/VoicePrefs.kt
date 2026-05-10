// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.content.Context

data class VoicePrefs(
    val wakeWord: String = "hey papercup",
    val rate: Float = 1.0f,
    val pitch: Float = 1.0f,
    val voiceName: String? = null,
)

class VoicePrefsStore(context: Context) {
    private val sp = context.getSharedPreferences("papercup-voice-prefs", Context.MODE_PRIVATE)

    fun load(): VoicePrefs = VoicePrefs(
        wakeWord = sp.getString("wakeWord", "hey papercup") ?: "hey papercup",
        rate = sp.getFloat("rate", 1.0f),
        pitch = sp.getFloat("pitch", 1.0f),
        voiceName = sp.getString("voiceName", null),
    )

    fun save(p: VoicePrefs) {
        sp.edit()
            .putString("wakeWord", p.wakeWord)
            .putFloat("rate", p.rate)
            .putFloat("pitch", p.pitch)
            .apply { if (p.voiceName == null) remove("voiceName") else putString("voiceName", p.voiceName) }
            .apply()
    }
}

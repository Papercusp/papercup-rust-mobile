// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.content.Context

/** Copy shown immediately before the first ElevenLabs-powered voice session. */
object VoicePrivacyDisclosure {
    const val TITLE = "Allow cloud voice?"
    const val BODY = "Papercusp is an AI assistant. Cloud voice sends your microphone audio, transcripts, and responses to ElevenLabs and its service providers, including AI model providers. They may record, view, store, and share those communications to provide and improve the service, train models, and comply with law. Desktop-local voice does not send audio to ElevenLabs. You can withdraw permission in Settings."
    const val PRIVACY_URL = "https://papercusp.com/mobile/privacy"
    const val SUPPORT_URL = "https://papercusp.com/mobile/support"
}

class VoicePrivacyConsentStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isGranted(): Boolean = prefs.getBoolean(KEY, false)

    fun grant() = prefs.edit().putBoolean(KEY, true).apply()

    fun revoke() = prefs.edit().remove(KEY).apply()

    private companion object {
        const val PREFS = "papercup-privacy"
        const val KEY = "cloud-voice-consent-v1"
    }
}

internal fun requiresCloudVoiceConsent(isCloudMode: Boolean, isGranted: Boolean): Boolean =
    isCloudMode && !isGranted

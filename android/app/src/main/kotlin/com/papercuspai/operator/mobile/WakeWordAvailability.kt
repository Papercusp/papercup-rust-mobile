// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

/** A selected backend must implement detection before it can own the microphone. */
internal fun wakeWordEngineConfigured(accessKey: String, useOpenWakeWord: Boolean): Boolean =
    !useOpenWakeWord && accessKey.isNotBlank()

/** Display the same compiled phrase the selected detector actually recognizes. */
internal fun wakeWordKeyword(configured: Boolean, hasCustomKeyword: Boolean): String? = when {
    !configured -> null
    hasCustomKeyword -> "hey papercup"
    else -> "Jarvis"
}

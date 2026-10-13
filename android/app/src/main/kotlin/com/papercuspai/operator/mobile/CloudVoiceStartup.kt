// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/** The SDK startup boundary used by VoiceManager; Android and SDK work stays in its callbacks. */
internal suspend fun <T> runCloudVoiceStartup(
    isCurrent: () -> Boolean,
    start: suspend () -> T,
    accept: (T) -> Unit,
    closeStale: suspend (T) -> Unit,
    onFailure: (Throwable) -> Unit,
    release: () -> Unit,
) {
    try {
        val started = start()
        if (isCurrent()) accept(started) else withContext(NonCancellable) { closeStale(started) }
    } catch (cancelled: CancellationException) {
        if (isCurrent()) release()
        throw cancelled
    } catch (failure: Throwable) {
        if (isCurrent()) {
            try { onFailure(failure) } finally { release() }
        }
    }
}

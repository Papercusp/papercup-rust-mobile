// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

/** One mapping for the FCM Intent consumer and the existing tap diagnostic. */
internal sealed interface PushDestination {
    data class HarnessDetail(val slug: String) : PushDestination
    data class RunLog(val slug: String) : PushDestination
    data object Operator : PushDestination
    data object Inbox : PushDestination
}

internal fun resolvePushDestination(kind: String?, harness: String?): PushDestination {
    val slug = harness?.trim()?.takeIf { it.isNotEmpty() }
    return when (kind) {
        "smoke-fail" -> slug?.let { PushDestination.RunLog(it) } ?: PushDestination.Inbox
        "operator-suggestion" -> PushDestination.Operator
        null, "intervention", "needs-human", "plan-review" ->
            slug?.let { PushDestination.HarnessDetail(it) } ?: PushDestination.Inbox
        else -> PushDestination.Inbox
    }
}

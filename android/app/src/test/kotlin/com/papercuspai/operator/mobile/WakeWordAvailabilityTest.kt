// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WakeWordAvailabilityTest {
    @Test
    fun porcupineNeedsANonblankKey() {
        assertFalse(wakeWordEngineConfigured("", useOpenWakeWord = false))
        assertFalse(wakeWordEngineConfigured("  \t\n", useOpenWakeWord = false))
        assertTrue(wakeWordEngineConfigured("configured-key", useOpenWakeWord = false))
    }

    @Test
    fun unimplementedOpenWakeWordCannotStartTheMicrophone() {
        assertFalse(wakeWordEngineConfigured("", useOpenWakeWord = true))
    }

    @Test
    fun selectingOpenWakeWordDoesNotSilentlyUseThePaidBackend() {
        assertFalse(wakeWordEngineConfigured("configured-key", useOpenWakeWord = true))
    }

    @Test
    fun aBundledKeywordCannotMakeAnUnconfiguredEngineAvailable() {
        assertNull(wakeWordKeyword(configured = false, hasCustomKeyword = false))
        assertNull(wakeWordKeyword(configured = false, hasCustomKeyword = true))
    }

    @Test
    fun missingCustomModelDisplaysTheActualBuiltinKeyword() {
        assertEquals("Jarvis", wakeWordKeyword(configured = true, hasCustomKeyword = false))
    }

    @Test
    fun bundledCustomModelDisplaysHeyPapercup() {
        assertEquals("hey papercup", wakeWordKeyword(configured = true, hasCustomKeyword = true))
    }
}

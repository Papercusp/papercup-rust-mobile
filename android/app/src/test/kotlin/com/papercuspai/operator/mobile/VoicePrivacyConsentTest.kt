// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VoicePrivacyConsentTest {
    @Test
    fun cloudVoiceIsBlockedUntilConsent() {
        assertTrue(requiresCloudVoiceConsent(isCloudMode = true, isGranted = false))
        assertFalse(requiresCloudVoiceConsent(isCloudMode = true, isGranted = true))
    }

    @Test
    fun desktopLocalVoiceDoesNotRequireCloudConsent() {
        assertFalse(requiresCloudVoiceConsent(isCloudMode = false, isGranted = false))
    }

    @Test
    fun disclosureNamesCloudProcessorsAndDataUse() {
        val text = VoicePrivacyDisclosure.BODY.lowercase()
        assertTrue(text.contains("elevenlabs"))
        assertTrue(text.contains("microphone audio"))
        assertTrue(text.contains("record"))
        assertTrue(text.contains("store"))
        assertTrue(text.contains("train models"))
        assertTrue(text.contains("withdraw permission"))
        assertTrue(VoicePrivacyDisclosure.PRIVACY_URL.startsWith("https://"))
    }

    @Test
    fun inAppPolicyDisclosesEveryShippedProcessor() {
        val policy = MobilePrivacyPolicy.sections.joinToString(" ") { it.body }.lowercase()
        assertTrue(policy.contains("elevenlabs"))
        assertTrue(policy.contains("firebase cloud messaging"))
        assertTrue(policy.contains("firebase crashlytics"))
        assertTrue(policy.contains("firebase analytics"))
        assertTrue(policy.contains("withdraw consent"))
    }
}

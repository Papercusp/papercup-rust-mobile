// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.Manifest
import android.os.Build
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PapercupAppSmokeTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    @Before
    fun requireFreshUnpairedFixture() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        // Fail rather than deleting a device's existing pairing. The runner
        // must supply a dedicated fresh emulator for these native journeys.
        assertNull("Native pairing tests require an unpaired fixture", CredentialStore(context).load())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            instrumentation.uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    @Test
    fun launcherActivityStarts() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                assertEquals("com.papercuspai.operator.mobile", activity.packageName)
                assertFalse(activity.isFinishing)
            }
        }
    }

    @Test
    fun invalidPastedPayloadStaysUnpairedAndReturnsToChoice() {
        ActivityScenario.launch(MainActivity::class.java).use {
            compose.onNodeWithText("Pair with your desktop").assertIsDisplayed()
            compose.onNodeWithText("Paste manually").performClick()
            compose.onNode(hasSetTextAction()).performTextInput("not a pairing payload")
            compose.onNodeWithText("Pair").performClick()
            compose.onNodeWithText("That payload doesn't look right", substring = true).assertIsDisplayed()
            assertNull(CredentialStore(InstrumentationRegistry.getInstrumentation().targetContext).load())
            compose.onNodeWithText("Back").performClick()
            compose.onNodeWithText("Scan QR").assertIsDisplayed()
        }
    }

    @Test
    fun insecureNonLoopbackPayloadIsRejectedWithoutPersistingCredentials() {
        ActivityScenario.launch(MainActivity::class.java).use {
            compose.onNodeWithText("Paste manually").performClick()
            compose.onNode(hasSetTextAction()).performTextInput(
                """{"server":"http://example.invalid","pairToken":"native-fixture-only","workspaceId":"native-fixture"}""",
            )
            compose.onNodeWithText("Pair").performClick()
            compose.onNodeWithText("Papercusp requires a secure HTTPS desktop address.", substring = true).assertIsDisplayed()
            assertNull(CredentialStore(InstrumentationRegistry.getInstrumentation().targetContext).load())
        }
    }
}

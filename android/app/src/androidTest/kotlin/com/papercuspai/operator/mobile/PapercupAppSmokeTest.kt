// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.Manifest
import android.content.Intent
import android.os.Build
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlinx.coroutines.runBlocking
import org.json.JSONObject

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
            // The normal CI launcher check remains fixture-free. The live
            // runner selects this same maintained test with an owned fixture
            // to exercise real pairing/JNI, without a skip or an app backdoor.
            if (InstrumentationRegistry.getArguments().getString("nativePairingFixture") == "true") {
                verifyOwnedPairedJourney(scenario)
            }
        }
    }

    private fun verifyOwnedPairedJourney(scenario: ActivityScenario<MainActivity>) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val fixture = JSONObject(File(context.filesDir, "native-pairing-fixture.json").readText())
        assertEquals(1, fixture.getInt("schemaVersion"))
        val runId = fixture.getString("runId")
        assertTrue(runId.matches(Regex("[a-f0-9]{32}")))
        val expectedWorkspace = fixture.getString("workspaceId")
        val store = CredentialStore(context)
        val resultFile = File(context.filesDir, "native-pairing-result.json")
        val result = JSONObject().put("runId", runId).put("journeyCompleted", false)
        var ownedDevice: String? = null
        try {
            compose.onNodeWithText("Paste manually").performClick()
            compose.onNode(hasSetTextAction()).performTextInput(fixture.getJSONObject("pairPayload").toString())
            compose.onNodeWithText("Pair").performClick()
            compose.waitUntil(30_000) { store.load() != null }
            val paired = requireNotNull(store.load())
            ownedDevice = paired.deviceId
            result.put("deviceId", paired.deviceId).put("workspaceId", paired.workspaceId)
            resultFile.writeText(result.toString())
            assertEquals(expectedWorkspace, paired.workspaceId)
            assertTrue(paired.deviceToken.isNotBlank())
            // This device-JWT endpoint verifies the persisted token through
            // real JNI and HTTP, independently of the rendered paired shell.
            val devices = runBlocking { paired.client().listDesktopDevices() }
            assertTrue("Paired device must be returned by its authenticated scope", devices.any { it.deviceId == paired.deviceId })
            result.put("authenticatedRequestPassed", true)

            // Pairing may hand off to mesh enrollment. Return to the native
            // app as a user would, then prove credentials survive recreation.
            instrumentation.runOnMainSync {
                context.startActivity(Intent(context, MainActivity::class.java).addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
                ))
            }
            scenario.recreate()
            val restored = requireNotNull(store.load())
            assertEquals(paired.deviceId, restored.deviceId)
            assertEquals(paired.workspaceId, restored.workspaceId)
            assertTrue("Pairing token must survive recreation", paired.deviceToken == restored.deviceToken)
            compose.waitUntil(30_000) {
                compose.onAllNodes(androidx.compose.ui.test.hasContentDescription("Inbox")).fetchSemanticsNodes().isNotEmpty()
            }
            for (tab in listOf("Inbox", "Operator", "Plans", "Fleet", "Settings")) {
                compose.onNodeWithContentDescription(tab).assertIsDisplayed()
            }
            compose.onNodeWithContentDescription("Settings").performClick()
            compose.onNodeWithText(expectedWorkspace).assertIsDisplayed()
            compose.onNodeWithText("Diagnostics").performScrollTo().performClick()
            compose.onNodeWithText("Ping desktop").assertIsDisplayed()
            result.put("navigationPassed", true).put("journeyCompleted", true)
        } finally {
            val remaining = store.load()
            if (ownedDevice != null && remaining != null) {
                assertEquals("Refusing to clear another pairing", ownedDevice, remaining.deviceId)
                store.clear()
            }
            result.put("credentialsCleared", store.load() == null)
            resultFile.writeText(result.toString())
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

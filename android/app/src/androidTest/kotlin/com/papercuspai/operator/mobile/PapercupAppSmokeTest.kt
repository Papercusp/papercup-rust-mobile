// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.Manifest
import android.content.Intent
import android.os.Build
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasAnySibling
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.espresso.intent.Intents
import androidx.test.espresso.intent.matcher.IntentMatchers.hasAction
import androidx.test.espresso.intent.matcher.IntentMatchers.hasData
import org.hamcrest.Matchers.allOf
import org.junit.After
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
import org.json.JSONArray
import org.json.JSONObject
import uniffi.papercup.ApiException

@RunWith(AndroidJUnit4::class)
class PapercupAppSmokeTest {
    private var enrollmentIntentFixture = false
    @get:Rule
    val compose = createEmptyComposeRule()

    @Before
    fun requireFreshUnpairedFixture() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        // Fail rather than deleting a device's existing pairing. The runner
        // must supply a dedicated fresh emulator for these native journeys.
        assertNull("Native pairing tests require an unpaired fixture", CredentialStore(context).load())
        if (InstrumentationRegistry.getArguments().getString("nativePairingFixture") == "true") {
            // The owned native journey verifies our outgoing enrollment
            // intent, while full external browser/mesh enrollment has its own
            // acceptance plane. A fresh Chrome first-run screen is outside
            // this test and can otherwise steal focus after pairing.
            Intents.init()
            enrollmentIntentFixture = true
            Intents.intending(hasAction(Intent.ACTION_VIEW)).respondWith(
                android.app.Instrumentation.ActivityResult(android.app.Activity.RESULT_CANCELED, null),
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            instrumentation.uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    @After
    fun releaseEnrollmentIntentFixture() {
        if (enrollmentIntentFixture) Intents.release()
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
            .put("enrollmentBrowserStubbed", enrollmentIntentFixture)
        var ownedDevice: String? = null
        var stage = "pair-form"
        try {
            compose.onNodeWithText("Paste manually").performClick()
            compose.onNode(hasSetTextAction()).performTextInput(fixture.getJSONObject("pairPayload").toString())
            compose.onNodeWithText("Pair").performClick()
            stage = "persisted-credentials"
            compose.waitUntil(30_000) { store.load() != null }
            val paired = requireNotNull(store.load())
            ownedDevice = paired.deviceId
            result.put("deviceId", paired.deviceId).put("workspaceId", paired.workspaceId)
            resultFile.writeText(result.toString())
            assertEquals(expectedWorkspace, paired.workspaceId)
            assertTrue(paired.deviceToken.isNotBlank())
            paired.defguardEnrollmentUrl?.takeIf { it.isNotBlank() }?.let { url ->
                Intents.intended(allOf(hasAction(Intent.ACTION_VIEW), hasData(android.net.Uri.parse(url))))
                result.put("enrollmentIntentObserved", true)
            }
            // This device-JWT endpoint verifies the persisted token through
            // real JNI and HTTP, independently of the rendered paired shell.
            stage = "authenticated-jni-request"
            val devices = runBlocking { paired.client().listDesktopDevices() }
            assertTrue("Paired device must be returned by its authenticated scope", devices.any { it.deviceId == paired.deviceId })
            result.put("authenticatedRequestPassed", true)

            // Pairing may hand off to mesh enrollment. Return to the native
            // app as a user would, then prove credentials survive recreation.
            stage = "return-to-paired-shell"
            instrumentation.runOnMainSync {
                context.startActivity(Intent(context, MainActivity::class.java).addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
                ))
            }
            waitForPairedShell()
            result.put("returnedToPairedShell", true)
            stage = "activity-recreation"
            scenario.recreate()
            val restored = requireNotNull(store.load())
            assertEquals(paired.deviceId, restored.deviceId)
            assertEquals(paired.workspaceId, restored.workspaceId)
            assertTrue("Pairing token must survive recreation", paired.deviceToken == restored.deviceToken)
            waitForPairedShell()
            result.put("activityRecreated", true)
            stage = "scoped-inbox"
            verifyOwnedInbox(paired, result)
            result.put("inboxRenderingPassed", true)

            // Exercise the real JNI/HTTP authorization boundary without
            // revoking any other device or changing the desktop selection.
            // This is an invalid-JWT fixture, not proof of expiry/revocation.
            stage = "inbox-invalid-session"
            val invalid = paired.copy(deviceToken = "native-invalid-device-jwt")
            val rejected = runCatching { runBlocking { invalid.client().attention() } }.exceptionOrNull()
            assertTrue("Invalid device JWT must be rejected by the real Inbox endpoint", rejected is ApiException.Unauthorized)
            store.save(invalid)
            scenario.recreate()
            waitForPairedShell()
            compose.onNodeWithContentDescription("Inbox").performClick()
            waitForText("Could not load inbox")
            compose.onNodeWithText("Inbox status unavailable").assertIsDisplayed()
            compose.onNodeWithText("Loading the inbox failed — this device's pairing is no longer valid. Re-pair with your Papercup server from Settings.")
                .assertIsDisplayed()
            compose.onNodeWithContentDescription("Inbox status unavailable").assertIsDisplayed()
            compose.onNodeWithText("Inbox zero — nothing needs you right now.").assertDoesNotExist()
            result.put("inboxUnauthorizedPassed", true)

            stage = "inbox-session-recovery"
            store.save(paired)
            scenario.recreate()
            waitForPairedShell()
            verifyOwnedInbox(paired, result)
            result.put("inboxRecoveryPassed", true)
            stage = "paired-navigation"
            for (tab in listOf("Inbox", "Operator", "Plans", "Fleet", "Settings")) {
                compose.onNodeWithContentDescription(tab).assertIsDisplayed()
            }
            compose.onNodeWithContentDescription("Settings").performClick()
            compose.onNodeWithText("Workspace").assertIsDisplayed()
            compose.onNode(hasText(expectedWorkspace) and hasAnySibling(hasText("Workspace")))
                .assertIsDisplayed()
            if (!paired.defguardEnrollmentUrl.isNullOrBlank()) {
                compose.onNodeWithText("Enrollment link ready").assertIsDisplayed()
                result.put("meshEnrollmentClaimCorrect", true)
            }
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Diagnostics"))
            compose.onNodeWithText("Diagnostics").assertIsDisplayed().performClick()
            compose.onNodeWithText("Ping desktop").assertIsDisplayed()
            compose.onNodeWithText("Workspace").performScrollTo().assertIsDisplayed()
            compose.onNode(hasText(expectedWorkspace) and hasAnySibling(hasText("Workspace")))
                .assertIsDisplayed()
            result.put("valueRowLabelsPassed", true)
            result.put("navigationPassed", true).put("journeyCompleted", true)
        } catch (failure: Throwable) {
            result.put("failedStage", stage).put("failureClass", failure.javaClass.name)
            // Keep sensitive input only in the owned app's private storage;
            // the runner retains this image in its restricted evidence dir.
            runCatching {
                File(context.filesDir, "native-pairing-failure.png").outputStream().use { image ->
                    requireNotNull(instrumentation.uiAutomation.takeScreenshot())
                        .compress(android.graphics.Bitmap.CompressFormat.PNG, 100, image)
                }
            }.onFailure { result.put("diagnosticFailureClass", it.javaClass.name) }
            throw failure
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

    private fun waitForPairedShell() {
        // Enrollment handoff and recreation can temporarily detach every
        // Compose root. Wait for the actual shell within the same deadline;
        // an absent root is a pending transition, not an immediate exception.
        compose.waitUntil(30_000) {
            compose.onAllNodes(androidx.compose.ui.test.hasContentDescription("Inbox"))
                .fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
        }
    }

    private fun verifyOwnedInbox(paired: DeviceCredentials, result: JSONObject) {
        val feed = runBlocking { paired.client().attention() }
        // This runner creates a fresh private workspace with no harness or
        // work-item fixtures. Global system alerts may still be present.
        assertEquals("Private workspace must not leak other attention groups", 0L, feed.groupCount)
        assertEquals("Private workspace must not leak other work items", 0L, feed.workItemCount)
        assertTrue(feed.workItems.isEmpty())
        val groups = if (feed.groupsJson.trim().startsWith("[")) JSONArray(feed.groupsJson)
            else JSONObject(feed.groupsJson).getJSONArray("groups")
        assertEquals(0, groups.length())
        result.put("inboxScopedReadPassed", true).put("inboxSystemAlertCount", feed.systemAlerts.size)
        compose.onNodeWithContentDescription("Inbox").performClick()
        if (feed.systemAlerts.isEmpty()) {
            waitForText("Inbox zero — nothing needs you right now.")
        } else {
            waitForText("SYSTEM ALERTS")
            compose.onNodeWithText("Inbox zero — nothing needs you right now.").assertDoesNotExist()
        }
        compose.waitUntil(30_000) {
            compose.onAllNodes(androidx.compose.ui.test.hasContentDescription("Inbox status unavailable"))
                .fetchSemanticsNodes(atLeastOneRootRequired = false).isEmpty()
        }
        compose.onNodeWithText("Could not load inbox").assertDoesNotExist()
        compose.onNodeWithText("Inbox status unavailable").assertDoesNotExist()
    }

    private fun waitForText(text: String) {
        compose.waitUntil(30_000) {
            compose.onAllNodes(hasText(text)).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
        }
        compose.onNodeWithText(text).assertIsDisplayed()
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

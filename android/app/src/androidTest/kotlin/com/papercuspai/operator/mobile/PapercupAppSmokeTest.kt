// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.Manifest
import android.content.Intent
import android.os.Build
import androidx.activity.compose.setContent
import com.papercuspai.operator.mobile.theme.PapercupTheme
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasAnySibling
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onAllNodesWithTag
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
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import uniffi.papercup.ApiException
import uniffi.papercup.BiometricPrompt
import uniffi.papercup.BiometricResult
import java.util.concurrent.atomic.AtomicInteger

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
        if (InstrumentationRegistry.getArguments().getString("nativePairingFixture") == "true" ||
            InstrumentationRegistry.getArguments().getString("cloudPairing") == "true") {
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
    fun sixFeatureJourneysMatchOwnedOperatorState() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            if (InstrumentationRegistry.getArguments().getString("nativeFeatureFixture") == "true") {
                verifyOwnedPairedJourney(scenario, featuresOnly = true)
            } else {
                compose.onNodeWithText("Paste manually").assertIsDisplayed()
            }
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
            if (InstrumentationRegistry.getArguments().getString("cloudPairing") == "true") {
                verifyOwnedCloudJourney(scenario)
            }
        }
    }

    /** The public QR is unmodified; every request uses the production JNI transport. */
    private fun verifyOwnedCloudJourney(scenario: ActivityScenario<MainActivity>) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val input = JSONObject(File(context.filesDir, "cloud-pairing-input.json").readText())
        val payload = input.getJSONObject("pairPayload")
        val store = CredentialStore(context)
        val proofFile = File(context.filesDir, "cloud-pairing-result.json")
        val proof = JSONObject().put("runId", input.getString("runId"))
            .put("scope", "public hosted Android debug JNI/manual QR payload; no camera, BYOC or signed release claim")
        var owned: DeviceCredentials? = null
        fun stage(name: String) {
            proof.put("stage", name)
            proofFile.writeText(proof.toString())
        }
        try {
            stage("manual-public-qr")
            compose.onNodeWithText("Paste manually").performClick()
            compose.onNode(hasSetTextAction()).performTextInput(payload.toString())
            compose.onNodeWithText("Pair").performClick()
            compose.waitUntil(45_000) {
                // A refused native pair is terminal for this one-use QR. Keep
                // safe evidence and fail immediately instead of hiding it in
                // a 45-second credential wait. Never retain payload/token text.
                if (compose.onAllNodesWithTag("pairing-error").fetchSemanticsNodes().isNotEmpty()) {
                    proof.put("pairingErrorVisible", true)
                    stage("pairing-refused")
                    throw AssertionError("Native pairing displayed an error; inspect redacted pairing stages")
                }
                store.load() != null
            }
            owned = requireNotNull(store.load())
            val paired = owned!!
            proof.put("deviceId", paired.deviceId).put("workspaceId", paired.workspaceId)
            stage("encrypted-restore")
            assertEquals(payload.getString("server"), paired.server)
            assertEquals(payload.getString("workspaceId"), paired.workspaceId)
            assertEquals(payload.getString("noiseKey"), paired.noiseKey)
            assertTrue(!paired.noiseSeed.isNullOrBlank())
            waitForPairedShell()
            scenario.recreate()
            waitForPairedShell()
            val restored = requireNotNull(CredentialStore(context).load())
            assertEquals(paired, restored)
            proof.put("encryptedRestore", true)
            stage("fresh-client-reconnect-and-scope")
            repeat(2) {
                val client = restored.client()
                try {
                    runBlocking {
                        assertTrue(client.listDesktopDevices().any { it.deviceId == paired.deviceId })
                        assertTrue(client.listWorkspaces().any { it.id == paired.workspaceId })
                        client.listHarnesses()
                        client.attention()
                        client.listRunning()
                        client.runtimeConfig()
                        client.operatorConversation(1u)
                    }
                } finally { client.close() }
            }
            proof.put("reconnectAndScope", true).put("readOperations", true)
            stage("paired-shell")
            for (tab in listOf("Inbox", "Operator", "Plans", "Fleet", "Settings")) {
                compose.onNodeWithContentDescription(tab).assertIsDisplayed()
            }
            proof.put("navigation", true)
            stage("revoke-owned-device")
            val client = restored.client()
            try {
                client.setBiometricPrompt(object : BiometricPrompt {
                    override fun prompt(reason: String): BiometricResult = BiometricResult.Approved
                })
                runBlocking { client.revokeDevice(paired.deviceId) }
                proof.put("revoked", true)
            } finally { client.close() }
            val revoked = restored.client()
            try {
                assertTrue(runCatching { runBlocking { revoked.listDesktopDevices() } }
                    .exceptionOrNull() is ApiException.Unauthorized)
                proof.put("revokedTokenRejected", true)
            } finally { revoked.close() }
            stage("completed")
        } catch (failure: Throwable) {
            proof.put("failedStage", proof.getString("stage"))
                .put("failureClass", failure.javaClass.simpleName)
            proofFile.writeText(proof.toString())
            throw failure
        } finally {
            // Persist the device ref even after a failure so host-side cleanup is accountable.
            (owned ?: store.load())?.let { device ->
                proof.put("deviceId", device.deviceId)
                if (!proof.optBoolean("revoked")) {
                    val cleanup = device.client()
                    try {
                        cleanup.setBiometricPrompt(object : BiometricPrompt {
                            override fun prompt(reason: String): BiometricResult = BiometricResult.Approved
                        })
                        runBlocking { cleanup.revokeDevice(device.deviceId) }
                        proof.put("revoked", true)
                    } catch (failure: Throwable) {
                        proof.put("cleanupFailureClass", failure.javaClass.name)
                    } finally { cleanup.close() }
                }
            }
            // Retain encrypted recovery credentials if remote cleanup failed.
            if (proof.optBoolean("revoked")) store.clear()
            proof.put("credentialsCleared", store.load() == null)
            proofFile.writeText(proof.toString())
        }
    }

    private fun verifyOwnedPairedJourney(scenario: ActivityScenario<MainActivity>, featuresOnly: Boolean = false) {
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
        val ownedDevices = mutableSetOf<String>()
        val pairedDeviceIds = JSONArray()
        var stage = "pair-form"
        fun beginStage(value: String) {
            stage = value
            // A host deadline can interrupt JUnit before finally runs. Keep
            // the last operation on disk without treating progress as a pass.
            result.put("currentStage", value)
            resultFile.writeText(result.toString())
        }
        try {
            beginStage("pair-form")
            compose.onNodeWithText("Paste manually").performClick()
            compose.onNode(hasSetTextAction()).performTextInput(fixture.getJSONObject("pairPayload").toString())
            compose.onNodeWithText("Pair").performClick()
            beginStage("persisted-credentials")
            compose.waitUntil(30_000) { store.load() != null }
            var paired = requireNotNull(store.load())
            ownedDevice = paired.deviceId
            ownedDevices.add(paired.deviceId)
            pairedDeviceIds.put(paired.deviceId)
            result.put("deviceId", paired.deviceId).put("workspaceId", paired.workspaceId)
            resultFile.writeText(result.toString())
            assertEquals(expectedWorkspace, paired.workspaceId)
            assertTrue(paired.deviceToken.isNotBlank())
            paired.defguardEnrollmentUrl?.takeIf { it.isNotBlank() }?.let { url ->
                beginStage("enrollment-intent")
                Intents.intended(allOf(hasAction(Intent.ACTION_VIEW), hasData(android.net.Uri.parse(url))))
                result.put("enrollmentIntentObserved", true)
            }
            // This device-JWT endpoint verifies the persisted token through
            // real JNI and HTTP, independently of the rendered paired shell.
            beginStage("authenticated-jni-request")
            val devices = runBlocking { paired.client().listDesktopDevices() }
            assertTrue("Paired device must be returned by its authenticated scope", devices.any { it.deviceId == paired.deviceId })
            result.put("authenticatedRequestPassed", true)

            // Pairing may hand off to mesh enrollment. Return to the native
            // app as a user would, then prove credentials survive recreation.
            beginStage("return-to-paired-shell")
            instrumentation.runOnMainSync {
                context.startActivity(Intent(context, MainActivity::class.java).addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
                ))
            }
            waitForPairedShell()
            result.put("returnedToPairedShell", true)
            beginStage("activity-recreation")
            scenario.recreate()
            val restored = requireNotNull(store.load())
            assertEquals(paired.deviceId, restored.deviceId)
            assertEquals(paired.workspaceId, restored.workspaceId)
            assertTrue("Pairing token must survive recreation", paired.deviceToken == restored.deviceToken)
            waitForPairedShell()
            result.put("activityRecreated", true)
            if (featuresOnly) {
                beginStage("six-features")
                verifyOwnedFeatures(scenario, paired, result)
                result.put("journeyCompleted", true)
                return
            }
            verifyOwnedInbox(paired, result) { beginStage("inbox-initial-$it") }
            result.put("inboxRenderingPassed", true)

            // Exercise the real JNI/HTTP authorization boundary without
            // revoking any other device or changing the desktop selection.
            // This is an invalid-JWT fixture, not proof of expiry/revocation.
            beginStage("inbox-invalid-session")
            val invalid = paired.copy(deviceToken = "native-invalid-device-jwt")
            val rejected = runCatching { runBlocking { invalid.client().attention() } }.exceptionOrNull()
            assertTrue("Invalid device JWT must be rejected by the real Inbox endpoint", rejected is ApiException.Unauthorized)
            beginStage("inbox-invalid-rendering")
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

            beginStage("inbox-session-recovery")
            store.save(paired)
            scenario.recreate()
            waitForPairedShell()
            verifyOwnedInbox(paired, result) { beginStage("inbox-recovery-$it") }
            result.put("inboxRecoveryPassed", true)
            if (InstrumentationRegistry.getArguments().getString("nativeAuthFixture") == "true") {
                val auth = fixture.getJSONObject("auth")
                val control = paired.copy(deviceId = auth.getString("controlDeviceId"),
                    deviceToken = auth.getString("controlToken"))
                ownedDevices.add(control.deviceId)
                beginStage("expired-jwt-positive-control")
                verifyOwnedInbox(control, result) { beginStage("expired-control-$it") }
                result.put("expiredJwtControlPassed", true)
                val expired = control.copy(deviceToken = auth.getString("expiredToken"))
                beginStage("expired-jwt-rejection")
                assertTrue("A signed expired token must fail through actual JNI/HTTP",
                    runCatching { runBlocking { expired.client().attention() } }.exceptionOrNull() is ApiException.Unauthorized)
                result.put("expiredJwtRejected", true)
                showRejectedSession(scenario, expired)
                result.put("expiredJwtRenderingPassed", true)
                beginStage("expired-jwt-fresh-pair")
                paired = repairWithFreshPairing(auth.getJSONObject("expiredRepairPayload"), paired)
                ownedDevice = paired.deviceId
                ownedDevices.add(paired.deviceId)
                pairedDeviceIds.put(paired.deviceId)
                verifyOwnedInbox(paired, result) { beginStage("expired-repair-$it") }
                result.put("expiredJwtFreshPairPassed", true)

                beginStage("revocation-missing-prompt-control")
                val revokeClient = paired.client()
                assertTrue("High-risk revocation requires an explicit biometric approval",
                    runCatching { runBlocking { revokeClient.revokeDevice(paired.deviceId) } }
                        .exceptionOrNull() is ApiException.Unauthorized)
                verifyOwnedInbox(paired, result) { beginStage("revocation-missing-prompt-$it") }
                result.put("revocationMissingPromptBlocked", true)

                // This callback fixtures the platform decision only. The
                // actual UniFFI gate, HTTP revoke and rejected reads execute;
                // OS biometric UI and physical hardware remain separate proof.
                val expectedReason = "Revoke device ${paired.deviceId.take(8)}"
                val deniedPrompts = AtomicInteger()
                revokeClient.setBiometricPrompt(object : BiometricPrompt {
                    override fun prompt(reason: String): BiometricResult {
                        assertEquals(expectedReason, reason)
                        deniedPrompts.incrementAndGet()
                        return BiometricResult.Denied
                    }
                })
                beginStage("revocation-denied-prompt-control")
                assertTrue("Denied biometric approval must block revocation",
                    runCatching { runBlocking { revokeClient.revokeDevice(paired.deviceId) } }
                        .exceptionOrNull() is ApiException.Unauthorized)
                assertEquals(1, deniedPrompts.get())
                verifyOwnedInbox(paired, result) { beginStage("revocation-denied-prompt-$it") }
                result.put("revocationDeniedPromptBlocked", true)

                val approvedPrompts = AtomicInteger()
                revokeClient.setBiometricPrompt(object : BiometricPrompt {
                    override fun prompt(reason: String): BiometricResult {
                        assertEquals(expectedReason, reason)
                        approvedPrompts.incrementAndGet()
                        return BiometricResult.Approved
                    }
                })
                beginStage("actual-device-revocation")
                runBlocking { revokeClient.revokeDevice(paired.deviceId) }
                assertEquals(1, approvedPrompts.get())
                result.put("revocationApprovedPromptInvoked", true)
                    .put("revocationBiometricPromptStubbed", true)
                assertTrue("A revoked device must fail through actual JNI/HTTP",
                    runCatching { runBlocking { paired.client().attention() } }.exceptionOrNull() is ApiException.Unauthorized)
                result.put("revokedDeviceRejected", true)
                showRejectedSession(scenario, paired)
                result.put("revokedDeviceRenderingPassed", true)
                beginStage("revoked-device-fresh-pair")
                paired = repairWithFreshPairing(auth.getJSONObject("revokedRepairPayload"), paired)
                ownedDevice = paired.deviceId
                ownedDevices.add(paired.deviceId)
                pairedDeviceIds.put(paired.deviceId)
                scenario.recreate()
                waitForPairedShell()
                assertEquals(paired.deviceId, requireNotNull(store.load()).deviceId)
                verifyOwnedInbox(paired, result) { beginStage("revoked-repair-$it") }
                result.put("revokedDeviceFreshPairPassed", true)
                result.put("deviceId", paired.deviceId).put("pairedDeviceIds", pairedDeviceIds)
            }
            beginStage("paired-navigation")
            for (tab in listOf("Inbox", "Operator", "Plans", "Fleet", "Settings")) {
                compose.onNodeWithContentDescription(tab).assertIsDisplayed()
            }
            beginStage("settings-labels")
            compose.onNodeWithContentDescription("Settings").performClick()
            compose.onNodeWithText("Workspace").assertIsDisplayed()
            compose.onNode(hasText(expectedWorkspace) and hasAnySibling(hasText("Workspace")))
                .assertIsDisplayed()
            if (!paired.defguardEnrollmentUrl.isNullOrBlank()) {
                compose.onNodeWithText("Enrollment link ready").assertIsDisplayed()
                result.put("meshEnrollmentClaimCorrect", true)
            }
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Diagnostics"))
            beginStage("diagnostics-labels")
            compose.onNodeWithText("Diagnostics").assertIsDisplayed().performClick()
            compose.onNodeWithText("Ping desktop").assertIsDisplayed()
            compose.onNodeWithText("Workspace").performScrollTo().assertIsDisplayed()
            compose.onNode(hasText(expectedWorkspace) and hasAnySibling(hasText("Workspace")))
                .assertIsDisplayed()
            result.put("valueRowLabelsPassed", true)
            result.put("navigationPassed", true).put("journeyCompleted", true)
        } catch (failure: Throwable) {
            result.put("failedStage", stage).put("failureClass", failure.javaClass.name)
            // Record the generated bridge's actual outstanding handle count,
            // and stack metadata, before fixture cleanup cancels app work.
            // No payload, token, thread-local value or exception message is
            // included. Together with host response-finish timing this can
            // distinguish a pending Rust callback from a resumed UI task.
            runCatching {
                val threads = Thread.getAllStackTraces().entries
                    .filter { (thread, frames) -> thread.name == "main" || frames.any {
                        it.className.startsWith("uniffi.") || it.className.startsWith("com.sun.jna.")
                    } }
                    .sortedBy { it.key.name }
                val rows = JSONArray()
                for ((thread, frames) in threads.take(32)) {
                    rows.put(JSONObject().put("name", thread.name).put("state", thread.state.name)
                        .put("frames", JSONArray(frames.take(32).map { it.toString() })))
                }
                result.put("asyncFailureWitness", JSONObject()
                    .put("observedAtMillis", System.currentTimeMillis())
                    .put("uniffiPendingContinuations", uniffi.papercup.uniffiContinuationHandleMap.size)
                    .put("threads", rows).put("matchingThreadCount", threads.size))
            }.onFailure { result.put("asyncWitnessFailureClass", it.javaClass.name) }
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
                assertTrue("Refusing to clear another pairing", remaining.deviceId in ownedDevices)
                assertEquals(expectedWorkspace, remaining.workspaceId)
                store.clear()
            }
            result.put("credentialsCleared", store.load() == null)
            if (result.optBoolean("journeyCompleted") && result.optBoolean("credentialsCleared")) {
                result.put("currentStage", "completed")
            }
            resultFile.writeText(result.toString())
        }
    }

    private fun verifyOwnedFeatures(scenario: ActivityScenario<MainActivity>, paired: DeviceCredentials, result: JSONObject) {
        val expected = JSONObject()
        val client = paired.client()
        // Read independently through JNI before entering each screen. The
        // private workspace deliberately has no conversation/plans/candidates.
        val conversation = runBlocking { client.operatorConversation(50u) }
        assertTrue("Owned conversation must start empty", conversation.turns.isEmpty())
        compose.onNodeWithContentDescription("Operator").performClick()
        waitForText("Ask the operator anything.")
        compose.onNode(hasSetTextAction()).performTextInput("owned draft ${result.getString("runId")}")
        expected.put("chatTurns", conversation.turns.size)
        result.put("chatStatePassed", true)

        val plans = runBlocking { client.plansList(null, false) }
        compose.onNodeWithContentDescription("Plans").performClick()
        waitForText("${plans.size} plans")
        if (plans.isEmpty()) waitForText("No plans.")
        expected.put("plans", plans.size)
        result.put("plansStatePassed", true)

        val activity = runBlocking { client.fleetActivity() }
        compose.onNodeWithContentDescription("Fleet").performClick()
        waitForText("fleet activity ▸")
        compose.onNodeWithText("fleet activity ▸").performClick()
        waitForText("Fleet activity")
        waitForText(fleetAvailabilityText(activity))
        expected.put("fleetAvailability", fleetAvailabilityText(activity))
        result.put("fleetStatePassed", true)

        // Fleet activity is a detail route without the shell's pot switcher.
        // Exercise its real back handler before continuing shell navigation.
        scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
        waitForPairedShell()
        val pots = runBlocking { client.listHarnesses() }
        waitForText("All Pots ▾")
        compose.onNodeWithText("All Pots ▾").performClick()
        if (pots.isEmpty()) waitForText("No pots available")
        else {
            val pot = pots.first().slug
            compose.onNodeWithText(pot).performClick()
            waitForText("$pot ▾")
            compose.onNodeWithText("$pot ▾").performClick()
        }
        compose.onNodeWithText("All Pots").performClick()
        val workspaces = runBlocking { client.listWorkspaces() }
        val workspace = workspaces.first { it.id == paired.workspaceId }
        compose.onNodeWithContentDescription("Settings").performClick()
        compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Workspace selector"))
        compose.onNodeWithText("Workspace selector").performClick()
        waitForText("Workspace selector")
        compose.onAllNodes(hasText(workspace.name)).fetchSemanticsNodes().also { assertTrue(it.isNotEmpty()) }
        compose.onNodeWithContentDescription("Back").performClick()
        expected.put("pots", pots.size).put("workspaceId", workspace.id).put("workspaceName", workspace.name)
        result.put("workspacePotStatePassed", true)

        compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Diagnostics"))
        compose.onNodeWithText("Diagnostics").performClick()
        runBlocking { client.heartbeat() }
        compose.onNodeWithText("Ping desktop").performClick()
        waitForText("ONLINE")
        result.put("diagnosticsStatePassed", true)
        compose.onNodeWithContentDescription("Back").performClick()

        compose.onNodeWithContentDescription("Inbox").performClick()
        verifyOwnedInbox(paired, result) { result.put("currentStage", "features-attention-$it") }
        val candidates = runBlocking { client.standingCandidates() }
        scenario.onActivity { host -> host.setContent { PapercupTheme { StandingApprovalsScreen(paired, {}) } } }
        waitForText("${candidates.size} pending")
        if (candidates.isEmpty()) waitForText("No standing-approval candidates.")
        expected.put("standingCandidates", candidates.size)
        result.put("attentionApprovalsStatePassed", true).put("featureExpectedState", expected)
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

    private fun showRejectedSession(scenario: ActivityScenario<MainActivity>, rejected: DeviceCredentials) {
        CredentialStore(InstrumentationRegistry.getInstrumentation().targetContext).save(rejected)
        scenario.recreate()
        waitForPairedShell()
        compose.onNodeWithContentDescription("Inbox").performClick()
        waitForText("Could not load inbox")
        compose.onNodeWithText("Inbox status unavailable").assertIsDisplayed()
        compose.onNodeWithText("Loading the inbox failed — this device's pairing is no longer valid. Re-pair with your Papercup server from Settings.")
            .assertIsDisplayed()
        compose.onNodeWithText("Inbox zero — nothing needs you right now.").assertDoesNotExist()
    }

    private fun repairWithFreshPairing(payload: JSONObject, previous: DeviceCredentials): DeviceCredentials {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val store = CredentialStore(context)
        compose.onNodeWithContentDescription("Settings").performClick()
        val forget = context.getString(R.string.settings_forget_device)
        compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText(forget))
        compose.onNodeWithText(forget).performClick()
        waitForText("Paste manually")
        assertNull("Settings must discard the invalid credentials", store.load())
        compose.onNodeWithText("Paste manually").performClick()
        compose.onNode(hasSetTextAction()).performTextInput(payload.toString())
        compose.onNodeWithText("Pair").performClick()
        compose.waitUntil(30_000) { store.load()?.deviceId?.let { it != previous.deviceId } == true }
        val fresh = requireNotNull(store.load())
        assertEquals(previous.workspaceId, fresh.workspaceId)
        assertEquals(previous.server, fresh.server)
        assertTrue("Recovery must persist a fresh token", previous.deviceToken != fresh.deviceToken)
        waitForPairedShell()
        return fresh
    }

    private fun verifyOwnedInbox(paired: DeviceCredentials, result: JSONObject, beginStage: (String) -> Unit) {
        beginStage("jni-request")
        val feed = runBlocking { paired.client().attention() }
        val groups = if (feed.groupsJson.trim().startsWith("[")) JSONArray(feed.groupsJson)
            else JSONObject(feed.groupsJson).getJSONArray("groups")
        // Capture bounded scope metadata before assertions, so a failed native
        // run distinguishes actual foreign content from host-global controls.
        val scopes = JSONArray()
        for (g in 0 until groups.length()) {
            val group = groups.getJSONObject(g)
            val items = group.getJSONArray("items")
            val itemScopes = JSONArray()
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                itemScopes.put(JSONObject().put("id", item.opt("id"))
                    .put("kind", item.opt("kind")).put("harnessSlug", item.opt("harnessSlug"))
                    .put("planSlug", item.opt("planSlug")))
            }
            scopes.put(JSONObject().put("key", group.opt("key"))
                .put("harnessSlug", group.opt("harnessSlug")).put("planSlug", group.opt("planSlug"))
                .put("items", itemScopes))
        }
        result.put("inboxScopeWitness", JSONObject().put("groupCount", feed.groupCount)
            .put("workItemCount", feed.workItemCount).put("groups", scopes))
        beginStage("inbox-scope")
        assertEquals(groups.length().toLong(), feed.groupCount)
        assertPrivateWorkspaceGroups(groups)
        assertFalse(parseAttentionRows(feed.groupsJson).contentUnavailable)
        assertEquals("Private workspace must not leak other work items", 0L, feed.workItemCount)
        assertTrue(feed.workItems.isEmpty())
        result.put("inboxScopedReadPassed", true).put("inboxSystemAlertCount", feed.systemAlerts.size)
        beginStage("rendering")
        compose.onNodeWithContentDescription("Inbox").performClick()
        if (feed.systemAlerts.isEmpty() && groups.length() == 0) {
            waitForText("Inbox zero — nothing needs you right now.")
        } else {
            waitForText(if (feed.systemAlerts.isNotEmpty()) "SYSTEM ALERTS" else "NEEDS YOU")
            compose.onNodeWithText("Inbox zero — nothing needs you right now.").assertDoesNotExist()
        }
        compose.waitUntil(30_000) {
            compose.onAllNodes(androidx.compose.ui.test.hasContentDescription("Inbox status unavailable"))
                .fetchSemanticsNodes(atLeastOneRootRequired = false).isEmpty()
        }
        compose.onNodeWithText("Could not load inbox").assertDoesNotExist()
        compose.onNodeWithText("Inbox status unavailable").assertDoesNotExist()
    }

    private fun assertPrivateWorkspaceGroups(groups: JSONArray) {
        // plans:attention source 13 reads the static dark-flag registry for
        // every workspace. Permit that exact global contract; tenant-backed
        // plans, harnesses, questions and work items remain forbidden here.
        for (g in 0 until groups.length()) {
            val group = groups.getJSONObject(g)
            assertEquals("alerts:workspace", group.getString("key"))
            assertEquals("alerts", group.getString("kind"))
            for (scope in listOf("harnessSlug", "planSlug")) {
                assertTrue(group.has(scope) && group.isNull(scope))
            }
            val items = group.getJSONArray("items")
            assertTrue(items.length() > 0)
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                assertEquals("dark-flag-ratification", item.getString("kind"))
                assertEquals("system-control", item.getString("category"))
                assertEquals("harness", item.getString("source"))
                for (scope in listOf("harnessSlug", "planSlug")) {
                    assertTrue(item.has(scope) && item.isNull(scope))
                }
                val ref = item.getJSONObject("ref")
                assertEquals("dark-flag-ratification", ref.getString("kind"))
                val flag = ref.getString("flagKey")
                assertTrue(flag.startsWith("papercusp-") && flag.length > "papercusp-".length)
                assertEquals("dark-flag-ratification:$flag", item.getString("id"))
            }
        }
    }

    @Test
    fun privateInboxScopeAcceptsOnlyDocumentedGlobalControls() {
        val valid = """[{"key":"alerts:workspace","kind":"alerts","harnessSlug":null,"planSlug":null,
            "items":[{"id":"dark-flag-ratification:papercusp-fixture","kind":"dark-flag-ratification",
            "category":"system-control","source":"harness","harnessSlug":null,"planSlug":null,
            "ref":{"kind":"dark-flag-ratification","flagKey":"papercusp-fixture"}}]}]"""
        assertPrivateWorkspaceGroups(JSONArray("[]"))
        assertPrivateWorkspaceGroups(JSONArray(valid))
        val controls: List<(JSONObject) -> Unit> = listOf(
            { it.put("harnessSlug", "foreign-harness") },
            { it.put("planSlug", "foreign-plan") },
            { it.put("key", "plan:foreign-plan") },
            { it.getJSONArray("items").getJSONObject(0).put("harnessSlug", "foreign-harness") },
            { it.getJSONArray("items").getJSONObject(0).put("planSlug", "foreign-plan") },
            { it.getJSONArray("items").getJSONObject(0).put("kind", "owner-question") },
            { it.getJSONArray("items").getJSONObject(0).put("category", "work-item") },
            { it.getJSONArray("items").getJSONObject(0).put("id", "foreign-work-item") },
            { it.getJSONArray("items").getJSONObject(0).getJSONObject("ref").put("kind", "plan-item") },
        )
        for (mutate in controls) {
            val groups = JSONArray(valid)
            mutate(groups.getJSONObject(0))
            assertThrows(AssertionError::class.java) { assertPrivateWorkspaceGroups(groups) }
        }
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

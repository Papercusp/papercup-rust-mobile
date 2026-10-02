// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.Manifest
import android.os.Build
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Native Compose/JNI fixtures; the real server JWT verifier is a separate floor. */
@RunWith(AndroidJUnit4::class)
class OperatorChatScreenTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    @Before
    fun prepareOwnedActivity() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assertNull("Chat tests require an unpaired owned emulator", CredentialStore(instrumentation.targetContext).load())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            instrumentation.uiAutomation.grantRuntimePermission(
                instrumentation.targetContext.packageName, Manifest.permission.POST_NOTIFICATIONS,
            )
        }
    }

    @Test
    fun unauthorizedSendKeepsDraftWithoutInventingAPersistedTurn() = verifyRejectedSend(401)

    @Test
    fun forbiddenSendKeepsDraftWithoutInventingAPersistedTurn() = verifyRejectedSend(403)

    @Test
    fun rejectedDraftSurvivesSettingsRoundTrip() = verifyShellRecovery("settings")

    @Test
    fun rejectedDraftSurvivesSameScopeRepairAndActivityRecreation() = verifyShellRecovery("same")

    @Test
    fun repairToAnotherWorkspaceDoesNotExposePreviousDraft() = verifyShellRecovery("workspace")

    @Test
    fun repairToAnotherServerDoesNotExposePreviousDraft() = verifyShellRecovery("server")

    private fun verifyShellRecovery(recovery: String) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val store = CredentialStore(context)
        val draft = "private rejected draft"
        val freshWorkspace = if (recovery == "workspace") "other-workspace" else "draft-workspace"
        val sends = AtomicInteger()
        val pairs = AtomicInteger()
        val persistedText = AtomicReference("")
        MockWebServer().use { first ->
            MockWebServer().use { second ->
                val dispatcher = object : Dispatcher() {
                    override fun dispatch(request: RecordedRequest): MockResponse = when {
                        request.path == "/api/device/pair" -> {
                            assertEquals("repair-fixture", JSONObject(request.body.readUtf8()).getString("pairToken"))
                            pairs.incrementAndGet()
                            MockResponse().setHeader("Content-Type", "application/json").setBody(
                                JSONObject().put("deviceToken", "fresh-draft-token")
                                    .put("deviceId", "fresh-draft-device").put("workspaceId", freshWorkspace)
                                    .put("desktopHost", "127.0.0.1").put("defguardEnrollmentUrl", JSONObject.NULL).toString(),
                            )
                        }
                        request.path == "/api/device/operator/conversation?limit=50" ->
                            MockResponse().setHeader("Content-Type", "application/json").setBody(
                                JSONObject().put("conversation", JSONObject().put("id", "draft-thread")
                                    .put("workspaceId", if (pairs.get() == 0) "draft-workspace" else freshWorkspace)
                                    .put("harnessSlug", JSONObject.NULL).put("status", "active")
                                    .put("startedAt", 1).put("endedAt", JSONObject.NULL))
                                    .put("turns", if (persistedText.get().isEmpty()) JSONArray() else JSONArray()
                                        .put(turn(1, "user", persistedText.get())).put(turn(2, "assistant", "Recovered reply")))
                                    .put("hasMoreEarlier", false).toString(),
                            )
                        request.path == "/api/device/operator/converse" -> {
                            val text = JSONObject(request.body.readUtf8()).getString("text")
                            if (sends.incrementAndGet() == 1) {
                                assertEquals(draft, text)
                                assertEquals("Bearer old-draft-token", request.getHeader("Authorization"))
                                MockResponse().setResponseCode(401).setBody("{\"error\":\"rejected\"}")
                            } else {
                                assertEquals(if (recovery in listOf("workspace", "server")) "new scope draft" else draft, text)
                                assertEquals("Bearer fresh-draft-token", request.getHeader("Authorization"))
                                persistedText.set(text)
                                MockResponse().setHeader("Content-Type", "text/event-stream")
                                    .setBody("event: delta\ndata: {\"text\":\"Recovered reply\"}\n\nevent: done\ndata: {}\n\n")
                            }
                        }
                        else -> MockResponse().setResponseCode(404)
                    }
                }
                first.dispatcher = dispatcher
                second.dispatcher = dispatcher
                first.start()
                second.start()
                store.save(DeviceCredentials(first.url("/").toString().trimEnd('/'),
                    "old-draft-token", "old-draft-device", "draft-workspace"))
                try {
                    ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                        compose.onNodeWithContentDescription("Operator").performClick()
                        compose.onNode(hasSetTextAction()).performTextInput(draft)
                        compose.onNodeWithText("Send").performClick()
                        val error = "Sending the message failed — this device's pairing is no longer valid. " +
                            "Re-pair with your Papercup server from Settings."
                        compose.waitUntil(10_000) { compose.onAllNodes(hasText(error)).fetchSemanticsNodes().isNotEmpty() }
                        compose.onNode(hasSetTextAction()).assertTextContains(draft)
                        compose.onNodeWithContentDescription("Settings").performClick()
                        if (recovery != "settings") {
                            compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Forget this device"))
                            compose.onNodeWithText("Forget this device").performClick()
                            compose.onNodeWithText("Paste manually").performClick()
                            val target = if (recovery == "server") second else first
                            compose.onNode(hasSetTextAction()).performTextInput(JSONObject()
                                .put("server", target.url("/").toString().trimEnd('/'))
                                .put("pairToken", "repair-fixture").put("workspaceId", freshWorkspace).toString())
                            compose.onNodeWithText("Pair").performClick()
                            compose.waitUntil(10_000) { store.load()?.deviceId == "fresh-draft-device" }
                        }
                        compose.onNodeWithContentDescription("Operator").performClick()
                        val expected = if (recovery in listOf("workspace", "server")) "" else draft
                        compose.onNode(hasSetTextAction()).assert(
                            SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString(expected)),
                        )
                        compose.onAllNodes(hasText(draft) and !hasSetTextAction()).assertCountEquals(0)
                        assertEquals("Navigation and pairing must not replay a rejected send", 1, sends.get())
                        if (recovery == "same") {
                            scenario.recreate()
                            compose.onNodeWithContentDescription("Operator").performClick()
                            compose.onNode(hasSetTextAction()).assertTextContains(draft)
                        }
                        if (recovery != "settings") {
                            if (expected.isEmpty()) compose.onNode(hasSetTextAction()).performTextInput("new scope draft")
                            compose.onNodeWithText("Send").performClick()
                            compose.waitUntil(10_000) { compose.onAllNodes(hasText("Recovered reply")).fetchSemanticsNodes().isNotEmpty() }
                            assertEquals(2, sends.get())
                            assertEquals(1, pairs.get())
                        }
                    }
                } finally {
                    assertEquals("Refusing to clear another pairing", if (pairs.get() > 0) "fresh-draft-device" else "old-draft-device",
                        store.load()?.deviceId)
                    store.clear()
                }
            }
        }
    }

    private fun verifyRejectedSend(status: Int) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertNull("Chat tests require an unpaired owned emulator", CredentialStore(context).load())
        val text = "native rejected draft $status"
        val reply = "Fresh reply ✓"
        val sends = AtomicInteger()
        MockWebServer().use { server ->
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    assertEquals("Bearer native-chat-fixture", request.getHeader("Authorization"))
                    return when {
                        request.method == "GET" && request.path == "/api/device/operator/conversation?limit=50" -> {
                            val turns = JSONArray()
                            if (sends.get() >= 2) {
                                turns.put(turn(1, "user", text)).put(turn(2, "assistant", "<say>$reply</say>"))
                            }
                            MockResponse().setHeader("Content-Type", "application/json")
                                .setBody(JSONObject().put("conversation", JSONObject()
                                    .put("id", "native-chat-thread").put("workspaceId", "native-chat-workspace")
                                    .put("harnessSlug", JSONObject.NULL).put("status", "active")
                                    .put("startedAt", 1).put("endedAt", JSONObject.NULL))
                                    .put("turns", turns).put("hasMoreEarlier", false).toString())
                        }
                        request.method == "POST" && request.path == "/api/device/operator/converse" -> {
                            assertEquals(text, JSONObject(request.body.readUtf8()).getString("text"))
                            if (sends.incrementAndGet() == 1) {
                                MockResponse().setResponseCode(status).setBody("{\"error\":\"rejected\"}")
                            } else {
                                MockResponse().setHeader("Content-Type", "text/event-stream")
                                    .setBody("event: delta\ndata: {\"text\":\"Fresh reply ✓\"}\n\n" +
                                        "event: done\ndata: {}\n\n")
                            }
                        }
                        else -> MockResponse().setResponseCode(404)
                    }
                }
            }
            server.start()
            val creds = DeviceCredentials(server.url("/").toString().trimEnd('/'),
                "native-chat-fixture", "native-chat-device", "native-chat-workspace")
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                scenario.onActivity { activity ->
                    activity.setContent {
                        var input by remember { mutableStateOf("") }
                        MaterialTheme { OperatorChatScreen(creds, 0, input) { input = it } }
                    }
                }
                compose.waitUntil(10_000) { server.requestCount >= 1 }
                compose.onNode(hasSetTextAction()).performTextInput(text)
                compose.onNodeWithText("Send").performClick()
                val error = "Sending the message failed — this device's pairing is no longer valid. " +
                    "Re-pair with your Papercup server from Settings."
                compose.waitUntil(10_000) { compose.onAllNodes(hasText(error)).fetchSemanticsNodes().isNotEmpty() }
                compose.onNode(hasSetTextAction()).assertTextContains(text)
                compose.onAllNodes(hasText(text) and !hasSetTextAction()).assertCountEquals(0)
                assertEquals("A rejection must not be replayed automatically", 1, sends.get())

                // The user explicitly retries; the resulting UI must reconcile
                // once against the persisted thread, without a duplicate bubble.
                compose.onNodeWithText("Send").performClick()
                compose.waitUntil(10_000) { compose.onAllNodes(hasText(reply)).fetchSemanticsNodes().isNotEmpty() }
                compose.waitUntil(10_000) { server.requestCount >= 4 }
                compose.onAllNodes(hasText(text) and !hasSetTextAction()).assertCountEquals(1)
                compose.onAllNodes(hasText(reply)).assertCountEquals(1)
                compose.onNode(hasSetTextAction()).assert(
                    SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString("")),
                )
                assertEquals(2, sends.get())
            }
            assertEquals("GET", requireNotNull(server.takeRequest(1, TimeUnit.SECONDS)).method)
        }
    }

    private fun turn(seq: Int, role: String, text: String): JSONObject = JSONObject()
        .put("id", "native-chat-turn-$seq").put("conversationId", "native-chat-thread")
        .put("seq", seq).put("role", role).put("text", text).put("source", "text_typed")
        .put("elConvId", JSONObject.NULL).put("audioUrl", JSONObject.NULL).put("createdAt", seq)
        .put("tools", JSONObject.NULL)
}

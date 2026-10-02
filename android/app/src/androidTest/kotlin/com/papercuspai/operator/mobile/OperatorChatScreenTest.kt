// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.Manifest
import android.os.Build
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
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
                    activity.setContent { MaterialTheme { OperatorChatScreen(creds, 0) } }
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
                compose.onNode(hasSetTextAction()).assertTextEquals("")
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

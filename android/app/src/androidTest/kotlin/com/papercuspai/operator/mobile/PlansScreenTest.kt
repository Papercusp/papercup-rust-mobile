// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.Manifest
import android.os.Build
import androidx.activity.compose.setContent
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.papercuspai.operator.mobile.theme.PapercupTheme
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Actual Compose/JNI parsing, using HTTP fixtures; live operator acceptance is separate. */
@RunWith(AndroidJUnit4::class)
class PlansScreenTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Before
    fun requireOwnedUnpairedDevice() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assertNull(CredentialStore(instrumentation.targetContext).load())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            instrumentation.uiAutomation.grantRuntimePermission(
                instrumentation.targetContext.packageName, Manifest.permission.POST_NOTIFICATIONS,
            )
        }
    }

    private fun verifyItems(items: Any, expected: String, absent: String? = null, alsoExpected: String? = null) {
        MockWebServer().use { server ->
            val plan = JSONObject().put("slug", "native-plan").put("harness", "fixture-pot")
                .put("title", "Native plan fixture").put("status", "active")
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = when {
                    request.path?.startsWith("/api/device/plans?") == true -> MockResponse()
                        .setBody(JSONObject().put("plans", JSONArray().put(plan)).toString())
                    request.path == "/api/device/plans/native-plan?harness=fixture-pot" -> MockResponse()
                        .setBody(JSONObject(plan.toString()).put("items", items).toString())
                    else -> MockResponse().setResponseCode(404)
                }.setHeader("Content-Type", "application/json")
            }
            server.start()
            val credentials = DeviceCredentials(server.url("/").toString().trimEnd('/'),
                "fixture-token", "fixture-device", "fixture-workspace")
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                scenario.onActivity { host ->
                    host.setContent { PapercupTheme { PlansScreen(credentials, 0, "fixture-pot") } }
                }
                waitFor("Native plan fixture")
                compose.onNodeWithText("Native plan fixture").performClick()
                waitFor(expected)
                alsoExpected?.let { waitFor(it) }
                absent?.let { compose.onNodeWithText(it).assertDoesNotExist() }
            }
        }
    }

    private fun waitFor(text: String) {
        compose.waitUntil(15_000) {
            compose.onAllNodes(hasText(text, substring = true))
                .fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
        }
    }

    @Test
    fun invalidItemsRenderAnErrorInsteadOfEmptyState() = verifyItems(
        JSONObject().put("unexpected", true), "response didn't match", "No items.",
    )

    @Test
    fun validEmptyItemsRenderEmptyState() = verifyItems(JSONArray(), "No items.")

    @Test
    fun malformedItemRowRendersAnErrorInsteadOfPartialState() = verifyItems(
        JSONArray().put(JSONObject().put("id", "P-001").put("text", "Retained valid item"))
            .put(JSONObject().put("id", " ")),
        "response didn't match", "Retained valid item",
    )

    @Test
    fun effectiveStatusAndUnknownStatusRenderWithoutInventingTodo() = verifyItems(
        JSONArray().put(JSONObject().put("id", "P-001").put("text", "Unknown item"))
            .put(JSONObject().put("id", "P-002").put("text", "Blocked item")
                .put("storedStatus", "todo").put("effectiveStatus", "blocked")),
        "unknown", "todo", "blocked",
    )
}

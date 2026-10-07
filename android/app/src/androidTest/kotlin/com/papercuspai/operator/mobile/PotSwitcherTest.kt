// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.Manifest
import android.os.Build
import androidx.activity.compose.setContent
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.papercuspai.operator.mobile.theme.PapercupTheme
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.TimeUnit

/** Exercises the real JNI list request and its rendered failure/recovery states. */
@RunWith(AndroidJUnit4::class)
class PotSwitcherTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Before fun requireOwnedUnpairedDevice() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assertNull(CredentialStore(instrumentation.targetContext).load())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            instrumentation.uiAutomation.grantRuntimePermission(
                instrumentation.targetContext.packageName, Manifest.permission.POST_NOTIFICATIONS,
            )
        }
    }

    @Test fun failedLoadRetriesAndSelectsPotWithoutReportingHealthyEmpty() = exerciseRecovery(
        "{\"harnesses\":[{\"slug\":\"fixture-pot\",\"path\":\"/fixture\",\"has_state\":true}]}",
        "fixture-pot",
    )

    @Test fun successfulEmptyLoadIsExplicitAfterRetry() = exerciseRecovery(
        "{\"harnesses\":[]}", "No pots available",
    )

    private fun exerciseRecovery(body: String, recoveredText: String) {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(401).setHeadersDelay(1, TimeUnit.SECONDS))
            server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(body))
            server.start()
            val creds = DeviceCredentials(server.url("/").toString().trimEnd('/'),
                "fixture-token", "fixture-device", "fixture-workspace")
            val selected = mutableStateOf<String?>(null)
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                scenario.onActivity { host ->
                    host.setContent { PapercupTheme { PotSwitcherBar(creds, selected.value) { selected.value = it } } }
                }
                waitFor("Loading pots… ▾")
                compose.onNodeWithText("All Pots ▾").assertDoesNotExist()
                waitFor("Pots unavailable ▾")
                compose.onNodeWithText("Loading pots… ▾").assertDoesNotExist()
                compose.onNodeWithText("Pots unavailable ▾").performClick()
                compose.onNodeWithText("All Pots").assertDoesNotExist()
                compose.onNodeWithText("No pots available").assertDoesNotExist()
                assertEquals("/api/device/harnesses", server.takeRequest(5, TimeUnit.SECONDS)?.path)
                compose.onNodeWithText("Retry").performClick()
                waitFor(recoveredText)
                compose.onNodeWithText("Pots unavailable ▾").assertDoesNotExist()
                assertEquals("/api/device/harnesses", server.takeRequest(5, TimeUnit.SECONDS)?.path)
                if (recoveredText == "fixture-pot") {
                    compose.onNodeWithText("fixture-pot").performClick()
                    waitFor("fixture-pot ▾")
                    compose.runOnIdle { assertEquals("fixture-pot", selected.value) }
                    compose.onNodeWithText("fixture-pot ▾").performClick()
                    compose.onNodeWithText("All Pots").performClick()
                    waitFor("All Pots ▾")
                    compose.runOnIdle { assertNull(selected.value) }
                } else {
                    compose.onNodeWithText("All Pots").assertExists()
                }
            }
        }
    }

    private fun waitFor(text: String) {
        compose.waitUntil(15_000) {
            compose.onAllNodes(hasText(text)).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
        }
    }
}

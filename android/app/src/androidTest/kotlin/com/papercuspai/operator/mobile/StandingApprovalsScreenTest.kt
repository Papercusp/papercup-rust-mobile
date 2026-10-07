// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.activity.compose.setContent
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertCountEquals
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
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.TimeUnit

/** Compose/JNI HTTP failure and recovery control; live acceptance is separate. */
@RunWith(AndroidJUnit4::class)
class StandingApprovalsScreenTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun failedLoadStopsLoadingAndRetryShowsMeasuredEmptyState() {
        assertNull(CredentialStore(InstrumentationRegistry.getInstrumentation().targetContext).load())
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(401))
            server.enqueue(MockResponse().setHeader("Content-Type", "application/json")
                .setBody("{\"candidates\":[]}"))
            server.start()
            val creds = DeviceCredentials(server.url("/").toString().trimEnd('/'),
                "fixture-token", "fixture-device", "fixture-workspace")
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                scenario.onActivity { host ->
                    host.setContent { PapercupTheme { StandingApprovalsScreen(creds, {}) } }
                }
                waitFor("Unavailable")
                compose.onNodeWithText("Loading…").assertDoesNotExist()
                compose.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.ProgressBarRangeInfo)).assertCountEquals(0)
                compose.onNodeWithText("No standing-approval candidates.").assertDoesNotExist()
                assertEquals("/api/device/operator/standing-candidates", server.takeRequest(5, TimeUnit.SECONDS)?.path)
                compose.onNodeWithText("Retry").performClick()
                waitFor("No standing-approval candidates.")
                compose.onNodeWithText("0 pending").assertExists()
                compose.onNodeWithText("Unavailable").assertDoesNotExist()
                assertEquals("/api/device/operator/standing-candidates", server.takeRequest(5, TimeUnit.SECONDS)?.path)
            }
        }
    }

    private fun waitFor(text: String) {
        compose.waitUntil(15_000) {
            compose.onAllNodes(hasText(text)).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
        }
    }
}

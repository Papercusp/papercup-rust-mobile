// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Real Activity/Compose routing; provider delivery and server authorization are separate floors. */
@RunWith(AndroidJUnit4::class)
class PushTapActivityTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    @Before
    fun requireOwnedUnpairedCandidate() {
        assertNull("Push tests require an owned unpaired candidate", CredentialStore(context).load())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            instrumentation.uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.POST_NOTIFICATIONS)
        }
        assertTrue("Notification routing must not silently skip delivery", manager.areNotificationsEnabled())
    }

    @Test
    fun coldHarnessAndInboxExtrasKeepHarnessDetail() = withOwnedActivity(
        Intent(context, MainActivity::class.java)
            .putExtra(EXTRA_DEEPLINK_SLUG, "cold-push-pot")
            .putExtra(EXTRA_DEEPLINK_INBOX, true)
            .putExtra(EXTRA_DEEPLINK_KIND, "intervention"),
    ) {
        assertHarnessDetail("cold-push-pot")
    }

    @Test
    fun warmHarnessNotificationKeepsHarnessDetail() = withOwnedActivity {
        tapNotification("intervention", "warm-push-pot", "push-test-harness")
        assertHarnessDetail("warm-push-pot")
    }

    @Test
    fun warmSmokeFailureNotificationOpensRunLog() = withOwnedActivity {
        tapNotification("smoke-fail", "push-run-pot", "push-test-smoke")
        waitFor(context.getString(R.string.run_log_title))
        compose.onNodeWithText(context.getString(R.string.run_log_title)).assertIsDisplayed()
        compose.onNodeWithText("HARNESS DETAIL").assertDoesNotExist()
    }

    @Test
    fun warmOperatorSuggestionOpensComposer() = withOwnedActivity {
        tapNotification("operator-suggestion", null, "push-test-operator")
        compose.waitUntil(15_000) {
            compose.onAllNodes(hasSetTextAction()).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
        }
        compose.onNode(hasSetTextAction()).assertIsDisplayed()
    }

    private fun withOwnedActivity(
        incoming: Intent? = null,
        assertions: () -> Unit,
    ) {
        val store = CredentialStore(context)
        MockWebServer().use { server ->
            // Screen destination is observable even when backend data is unavailable.
            // No real pairing, cloud service, or production token is used here.
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest) = MockResponse().setResponseCode(404)
            }
            server.start()
            store.save(DeviceCredentials(server.url("/").toString().trimEnd('/'),
                "push-fixture-token", DEVICE_ID, "push-fixture-workspace"))
            try {
                ActivityScenario.launch<MainActivity>(incoming ?: Intent(context, MainActivity::class.java)).use {
                    compose.waitForIdle()
                    assertions()
                }
            } finally {
                assertEquals("Refusing to clear a different pairing", DEVICE_ID, store.load()?.deviceId)
                store.clear()
                manager.cancelAll()
            }
        }
    }

    private fun tapNotification(kind: String, slug: String?, eventId: String) {
        showNotification(context, "Push fixture", "Open the fixture destination", slug, true, eventId, kind)
        compose.waitUntil(5_000) { manager.activeNotifications.any { it.id == eventId.hashCode() } }
        manager.activeNotifications.single { it.id == eventId.hashCode() }.notification.contentIntent.send()
        instrumentation.waitForIdleSync()
    }

    private fun assertHarnessDetail(slug: String) {
        waitFor("HARNESS DETAIL")
        compose.waitForIdle()
        compose.onNodeWithText("HARNESS DETAIL").assertIsDisplayed()
        compose.onNodeWithText(slug).assertIsDisplayed()
    }

    private fun waitFor(text: String) {
        compose.waitUntil(15_000) {
            compose.onAllNodes(hasText(text)).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
        }
    }

    private companion object { const val DEVICE_ID = "push-fixture-device" }
}

// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.ui.test.assertIsDisplayed
import android.Manifest
import android.os.Build
import androidx.activity.compose.setContent
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.papercuspai.operator.mobile.theme.PapercupTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DiagnosticsScreenTest {
    @get:Rule val compose = createEmptyComposeRule()
    private var activity: ActivityScenario<MainActivity>? = null

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

    @After
    fun closeActivity() {
        activity?.close()
    }

    private fun showDiagnostics(developerDiagnosticsEnabled: Boolean, onPushTap: () -> Unit = {}) {
        val credentials = DeviceCredentials("https://example.invalid", "test", "test-device", "test-workspace")
        val monitor = ConnectionMonitor(CoroutineScope(Dispatchers.Main), credentials)
        activity = ActivityScenario.launch(MainActivity::class.java).also { scenario ->
            scenario.onActivity { host ->
                host.setContent {
                    PapercupTheme {
                        DiagnosticsScreen(credentials, monitor, {}, onPushTap, developerDiagnosticsEnabled)
                    }
                }
            }
        }
    }

    @Test
    fun publicDiagnosticsKeepConnectionStatusWithoutDeveloperPushControls() {
        showDiagnostics(false)
        compose.onNodeWithText("Ping desktop").assertIsDisplayed()
        compose.onNodeWithText("Workspace").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Push tap test").assertDoesNotExist()
        compose.onNodeWithText("FCM status").assertDoesNotExist()
        compose.onNodeWithText("FCM token (first 12)").assertDoesNotExist()
    }

    @Test
    fun debugDiagnosticsRetainWorkingPushTestControl() {
        var opened = 0
        showDiagnostics(true) { opened++ }
        compose.onNodeWithText("Push tap test").performScrollTo().performClick()
        assertEquals(1, opened)
    }
}

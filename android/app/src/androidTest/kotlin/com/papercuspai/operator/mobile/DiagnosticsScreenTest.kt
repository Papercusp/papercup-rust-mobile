// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.papercuspai.operator.mobile.theme.PapercupTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DiagnosticsScreenTest {
    @get:Rule val compose = createComposeRule()

    private fun showDiagnostics(developerDiagnosticsEnabled: Boolean, onPushTap: () -> Unit = {}) {
        val credentials = DeviceCredentials("https://example.invalid", "test", "test-device", "test-workspace")
        val monitor = ConnectionMonitor(CoroutineScope(Dispatchers.Main), credentials)
        compose.setContent {
            PapercupTheme {
                DiagnosticsScreen(credentials, monitor, {}, onPushTap, developerDiagnosticsEnabled)
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

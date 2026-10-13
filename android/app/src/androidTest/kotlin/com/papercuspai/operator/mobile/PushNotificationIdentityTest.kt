// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.service.notification.StatusBarNotification
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Runs only on the release team's owned, unpaired candidate emulator. */
@RunWith(AndroidJUnit4::class)
class PushNotificationIdentityTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    @Before
    fun prepareOwnedCandidate() {
        assertNull("Requires the owned unpaired candidate", CredentialStore(context).load())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            instrumentation.uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.POST_NOTIFICATIONS)
        }
        assertTrue("Notification acceptance must not silently skip delivery", manager.areNotificationsEnabled())
        manager.cancelAll()
        awaitNotifications { it.isEmpty() }
    }

    @After
    fun removeTestNotifications() { manager.cancelAll() }

    private fun awaitNotifications(predicate: (List<StatusBarNotification>) -> Boolean): List<StatusBarNotification> {
        val deadline = SystemClock.elapsedRealtime() + 5_000
        do {
            val active = manager.activeNotifications.toList()
            if (predicate(active)) return active
            SystemClock.sleep(20)
        } while (SystemClock.elapsedRealtime() < deadline)
        throw AssertionError("Notification manager did not reach the expected state")
    }

    @Test
    fun anonymousNotificationsKeepDistinctTapIntents() {
        showNotification(context, "First", "First harness", "first", true, null, "intervention")
        showNotification(context, "Second", "Second harness", "second", true, null, "intervention")
        val active = awaitNotifications { it.size == 2 }
        assertNotEquals(active[0].id, active[1].id)
        assertNotEquals(active[0].notification.contentIntent, active[1].notification.contentIntent)
    }

    @Test
    fun repeatedEventUpdatesOneNotification() {
        showNotification(context, "First", "Before", "first", true, "same-event", "intervention")
        awaitNotifications { it.size == 1 }
        showNotification(context, "Updated", "After", "second", true, "same-event", "intervention")
        val active = awaitNotifications {
            it.size == 1 && it[0].notification.extras.getString("android.title") == "Updated"
        }
        assertEquals("same-event".hashCode(), active.single().id)
    }
}

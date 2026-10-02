// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.sun.jna.CallbackThreadInitializer
import com.sun.jna.Native
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.papercup.OperatorClient
import uniffi.papercup.uniffiRustFutureContinuationCallbackImpl

@RunWith(AndroidJUnit4::class)
class UniffiCallbackTest {
    @Test
    fun inlineNativeContinuationsCanReenterJna() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assertTrue(instrumentation.targetContext.applicationContext is PapercupApplication)
        // A test-only mutation control: selecting this argument must crash on
        // ART, independently proving that the default detach caused the fault.
        if (InstrumentationRegistry.getArguments().getString("nativeCallbackDetachControl") == "true") {
            Native.setCallbackThreadInitializer(
                uniffiRustFutureContinuationCallbackImpl,
                CallbackThreadInitializer(true, true),
            )
        }
        MockWebServer().use { server ->
            repeat(4) {
                // Ensure the Rust future suspends before the HTTP response.
                server.enqueue(MockResponse().setResponseCode(204).setHeadersDelay(50, TimeUnit.MILLISECONDS))
            }
            server.start()
            OperatorClient(server.url("/").toString().trimEnd('/'), "native-callback-fixture").use { client ->
                // Unconfined continuation dispatch deliberately resumes inside
                // the real JNA callback and enters the next generated FFI poll.
                runBlocking(Dispatchers.Unconfined) {
                    withTimeout(10_000) {
                        repeat(4) { client.registerPush("fcm", "native-callback-fixture") }
                    }
                }
            }
            assertEquals(4, server.requestCount)
            repeat(4) {
                val request = requireNotNull(server.takeRequest(1, TimeUnit.SECONDS))
                assertEquals("POST", request.method)
                assertEquals("/api/device/push/register", request.path)
            }
        }
    }
}

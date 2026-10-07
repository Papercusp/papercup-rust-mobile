// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.Base64
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import java.util.concurrent.TimeUnit
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.papercup.ApiException
import uniffi.papercup.OperatorClient
import uniffi.papercup.PairException
import uniffi.papercup.generateNoiseSeed
import uniffi.papercup.noisePublicKey
import uniffi.papercup.parseQrPayload

/** Real JNI and Keystore acceptance on an owned, initially unpaired emulator. */
@RunWith(AndroidJUnit4::class)
class SealedCredentialsTest {
    private lateinit var store: CredentialStore
    private var ownsStore = false

    @Before
    fun requireUnpairedFixture() {
        store = CredentialStore(InstrumentationRegistry.getInstrumentation().targetContext)
        assertNull("Sealed tests require an owned unpaired emulator", store.load())
        ownsStore = true
    }

    @After
    fun clearOwnedPairing() {
        if (ownsStore) store.clear()
    }

    @Test
    fun nativeKeyHelpersValidateQrAndPin() {
        val seed = Base64.getEncoder().encodeToString(ByteArray(32) { 1 })
        val expectedHex = "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c"
        val expected = expectedHex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        assertEquals(Base64.getEncoder().encodeToString(expected), noisePublicKey(seed))
        assertNotEquals(generateNoiseSeed(), generateNoiseSeed())
        val valid = JSONObject().put("server", "https://relay.test/api/workspaces/w")
            .put("pairToken", "test-token").put("workspaceId", "w")
            .put("noiseKey", noisePublicKey(seed))
        assertEquals(valid.getString("noiseKey"), parseQrPayload(valid.toString()).noiseKey)
        valid.put("noiseKey", Base64.getEncoder().encodeToString(ByteArray(32)))
        assertThrows(PairException.InvalidQr::class.java) { parseQrPayload(valid.toString()) }
        assertThrows(ApiException.Decode::class.java) {
            OperatorClient("https://relay.test", null).configureSealedTransport(seed, "bad-pin")
        }
    }

    @Test
    fun encryptedStoreRestoresIdentityAndRejectsPartialIdentity() {
        val seed = generateNoiseSeed()
        val pin = noisePublicKey(generateNoiseSeed())
        val credentials = DeviceCredentials("https://relay.test", "test-jwt", "test-device", "w",
            noiseSeed = seed, noiseKey = pin)
        store.save(credentials)
        val restored = CredentialStore(InstrumentationRegistry.getInstrumentation().targetContext).load()!!
        assertEquals(credentials, restored)
        restored.client().close()
        assertFalse(restored.toString().contains(seed))
        store.save(credentials.copy(noiseSeed = null))
        assertNull(store.load())
        store.save(credentials.copy(noiseKey = null))
        assertNull(store.load())
    }

    @Test
    fun restoredSealedClientNeverFallsBackToPlaintextWhenSocketCloses() = runBlocking {
        val server = MockWebServer()
        server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.close(1008, "test refusal")
            }
        }))
        server.start()
        try {
            val base = server.url("/api/workspaces/ws_1").toString()
            store.save(DeviceCredentials(base, "jwt-canary", "device-test", "ws_1",
                noiseSeed = generateNoiseSeed(), noiseKey = noisePublicKey(generateNoiseSeed())))
            val restored = CredentialStore(InstrumentationRegistry.getInstrumentation().targetContext).load()!!.client()
            try {
                restored.restQuery("proof", "{}")
                fail("Closed sealed channel must reject the request")
            } catch (_: ApiException.Network) {
                // The peer closed its socket before completing Noise.
            } finally {
                restored.close()
            }
            val request = server.takeRequest(5, TimeUnit.SECONDS)!!
            assertEquals("/api/workspaces/ws_1/api/device/sealed", request.path)
            assertNull(request.getHeader("Authorization"))
            assertEquals("No plaintext retry is permitted", 1, server.requestCount)
        } finally {
            server.shutdown()
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.Base64
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.papercup.ConverseDelta
import uniffi.papercup.OperatorClient
import uniffi.papercup.noisePublicKey
import uniffi.papercup.parseQrPayload

/** JNI → real maintained TS Noise/HTTP responder; VM fetch alone is a fixture. */
@RunWith(AndroidJUnit4::class)
class SealedTransportInteropTest {
    private lateinit var store: CredentialStore
    private lateinit var base: String
    private lateinit var pin: String
    private var ownsStore = false
    private val seed = Base64.getEncoder().encodeToString(ByteArray(32) { 0x31 })

    @Before
    fun requireOwnedFixture() {
        val args = InstrumentationRegistry.getArguments()
        base = requireNotNull(args.getString("sealedBase")) { "Use run-android-checks.sh sealed-native" }
        pin = requireNotNull(args.getString("sealedPin")) { "Real TS machine pin is required" }
        require(base.startsWith("http://127.0.0.1:")) { "Only the owned loopback fixture is allowed" }
        store = CredentialStore(InstrumentationRegistry.getInstrumentation().targetContext)
        assertNull("Interop needs an owned initially unpaired emulator", store.load())
        ownsStore = true
    }

    @After
    fun clearOwnedIdentity() {
        if (ownsStore) store.clear()
    }

    private suspend fun pairAndRestore(): DeviceCredentials {
        val qr = JSONObject().put("server", base).put("pairToken", "pair-canary")
            .put("workspaceId", "ws_1").put("noiseKey", pin)
        val payload = parseQrPayload(qr.toString())
        val anonymous = OperatorClient(payload.server, "old-device-token")
        val outcome = try {
            anonymous.configureSealedTransport(seed, payload.noiseKey!!)
            anonymous.pairWithNoise(payload.pairToken, noisePublicKey(seed))
        } finally {
            anonymous.close()
        }
        assertEquals("did-sealed", outcome.deviceId)
        assertEquals("ws_1", outcome.workspaceId)
        store.save(DeviceCredentials(payload.server, outcome.deviceToken, outcome.deviceId,
            outcome.workspaceId, noiseSeed = seed, noiseKey = payload.noiseKey))
        val restored = CredentialStore(InstrumentationRegistry.getInstrumentation().targetContext).load()!!
        assertEquals(seed, restored.noiseSeed)
        assertEquals(pin, restored.noiseKey)
        return restored
    }

    @Test
    fun qrPairEncryptedRestoreAndReconnectKeepIdentityAndBearerSealed() = runBlocking {
        val restored = pairAndRestore()
        repeat(2) {
            val client = restored.client()
            try {
                val rows = JSONObject(client.restQuery("test", "{}"))
                assertEquals("Bearer test-jwt", rows.getString("authorization"))
                assertFalse(rows.getBoolean("plaintextCanaryFound"))
                assertTrue(rows.getInt("maximumPacketBytes") < 512 * 1024)
            } finally {
                client.close()
            }
        }
    }

    @Test
    fun restoredNativeClientStreamsUtf8AndChunksLargeSealedUpload() = runBlocking {
        val restored = pairAndRestore()
        val client = restored.client()
        val deltas = mutableListOf<String>()
        try {
            client.operatorConverseStream("CANARY-private-🌍" + "x".repeat(700 * 1024),
                object : ConverseDelta {
                    override fun onDelta(text: String) { deltas.add(text) }
                })
            assertEquals("héllo 🌍", deltas[0])
            assertTrue(deltas[1].removePrefix("chunks=").toInt() > 14)
        } finally {
            client.close()
        }
    }
}

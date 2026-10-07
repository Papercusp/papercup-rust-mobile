// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.Base64
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeNotNull
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
    fun sealedPairAndRestoredJwtCrossRealTsResponder() = runBlocking {
        val arguments = InstrumentationRegistry.getArguments()
        val base = arguments.getString("sealedFixtureBase")
        val pin = arguments.getString("sealedFixtureKey")
        assumeNotNull(base, pin)
        // Same deterministic test identity as the maintained TS responder.
        val seed = Base64.getEncoder().encodeToString(ByteArray(32) { 0x31 })
        val client = OperatorClient(base!!, null)
        client.configureSealedTransport(seed, pin!!)
        val outcome = client.pairWithNoise("native-test-token", noisePublicKey(seed))
        assertEquals("did-sealed", outcome.deviceId)
        store.save(DeviceCredentials(base, outcome.deviceToken, outcome.deviceId, outcome.workspaceId,
            noiseSeed = seed, noiseKey = pin))
        val restored = CredentialStore(InstrumentationRegistry.getInstrumentation().targetContext).load()!!.client()
        val rows = JSONObject(restored.restQuery("proof", "{}")).getJSONObject("rows")
        assertEquals("Bearer test-jwt", rows.getString("authorization"))
        assertFalse(rows.getBoolean("plaintextCanaryFound"))
        restored.close()
        client.close()
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.Manifest
import android.os.Build
import androidx.activity.compose.setContent
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.papercuspai.operator.mobile.theme.PapercupTheme
import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LibraryNoticesScreenTest {
    @get:Rule val compose = createEmptyComposeRule()

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

    @Test
    fun unpairedRecipientCanOpenBundledLicenseTextAndReturn() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val libraries = context.resources.openRawResource(R.raw.aboutlibraries).bufferedReader().use {
            parseLibraryNotices(it.readText())
        }
        val library = libraries.libraries.first { row -> row.licenses.any { !it.licenseContent.isNullOrBlank() } }
        val text = requireNotNull(library.licenses.first { !it.licenseContent.isNullOrBlank() }.licenseContent)
        ActivityScenario.launch(MainActivity::class.java).use {
            compose.onNodeWithText("Third-party licenses").performClick()
            compose.waitUntil(15_000) { compose.onAllNodes(hasScrollToIndexAction()).fetchSemanticsNodes().isNotEmpty() }
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText(library.name))
            // Multiplatform wrapper and Android artifacts can share a name.
            compose.onAllNodes(hasText(library.name) and hasClickAction())[0].performClick()
            compose.onNodeWithText(text).assertExists()
            compose.onNodeWithText("OK").performClick()
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithText("Pair with your desktop").assertIsDisplayed()
            assertNull(CredentialStore(context).load())
        }
    }

    @Test
    fun bundledSupplementalNoticesMatchSourceAndOpenWithoutPairing() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val libraries = context.resources.openRawResource(R.raw.aboutlibraries).bufferedReader().use {
            parseLibraryNotices(it.readText())
        }
        // Source-pinned android/config/SOURCES.json. These hashes cover the
        // complete offline text, including both NIST and Sun/BEA SIP notices.
        // Updating a supplement requires reviewing and updating this guard.
        val supplements = listOf(
            Triple("androidx.camera:camera-core", "44d1a25c593283261968a15c8cc213cd",
                "2b2cc1180c7e6988328ad2033b04b80117419db9c4c584918bbb3cfec7e9364f"),
            Triple("io.github.webrtc-sdk:android-prefixed", "58a0fed5c0bf6a367ee905fc49842212",
                "ab00a482b6a3902e40211b43c5d0441962ea99b6cc7c25c0f243fa270b78d482"),
            Triple("com.google.mlkit:common", "9962f44671a86e167c028415c7e21548",
                "b1efdb95a59c9170929d5bf81f2c0b34cc61f6fa7dcf26635079644606817e89"),
            Triple("com.google.android.gms:play-services-basement", "ASDKL",
                "f046c8bbdfc36989e98e40b5915b2a09545d06c3ce204dd1f53f188604902976"),
            Triple("javax.sip:android-jain-sip-ri", "fa7f33c49aa6110f3cedeb2975e140e0",
                "dc6bd4b4a6fd417e4245b55d6f532cf482e56500350f8f8ac1890caaf8eec702"),
            Triple("io.livekit:livekit-android", "papercusp-livekit-notice",
                "1ddcdc49391b88daa34060c04a5c3ecaa324903abdca74010aad6edbd952ed72"),
            Triple("net.java.dev.jna:jna", "papercusp-jna-libffi",
                "2c9c2acb9743e6b007b91350475308aee44691d96aa20eacef8e199988c8c388"),
            Triple("androidx.graphics:graphics-path", "papercusp-graphics-path-notice",
                "09700dee0f298c3bde3435f539010e7f1b7ed50339a144d8907cd49094232a4b"),
            Triple("io.github.webrtc-sdk:android-prefixed", "papercusp-webrtc-third-party",
                "d1f9382c6878ac024155fd6d44a5977329108bb8b0a01cea40e4a2f1d7de252e"),
        )
        ActivityScenario.launch(MainActivity::class.java).use {
            compose.onNodeWithText("Third-party licenses").performClick()
            compose.waitUntil(15_000) { compose.onAllNodes(hasScrollToIndexAction()).fetchSemanticsNodes().isNotEmpty() }
            supplements.forEach { (module, licenseId, expectedSha256) ->
                val library = libraries.libraries.single { it.uniqueId == module }
                val license = library.licenses.single { it.hash == licenseId }
                val text = requireNotNull(license.licenseContent)
                val actualSha256 = MessageDigest.getInstance("SHA-256")
                    .digest(text.toByteArray(Charsets.UTF_8))
                    .joinToString("") { "%02x".format(it.toInt() and 0xff) }
                assertEquals("Complete bundled notice for $module", expectedSha256, actualSha256)
                compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText(library.name))
                compose.onAllNodes(hasText(library.name) and hasClickAction())[0].performClick()
                compose.onNodeWithText(text).assertExists()
                compose.onNodeWithText("OK").performClick()
            }
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithText("Pair with your desktop").assertIsDisplayed()
            assertNull(CredentialStore(context).load())
        }
    }

    @Test
    fun bundledRustSourceNoticeOpensWithoutPairing() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val libraries = context.resources.openRawResource(R.raw.aboutlibraries).bufferedReader().use {
            parseLibraryNotices(it.readText())
        }
        val library = libraries.libraries.single { it.uniqueId == "rust:uniffi:0.32.2" }
        val license = library.licenses.single { it.hash == "rust-1f256ecad192880510e84ad60474eab7589218784b9a50bc7ceee34c2b91f1d5" }
        val text = requireNotNull(license.licenseContent)
        val digest = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        assertEquals("1f256ecad192880510e84ad60474eab7589218784b9a50bc7ceee34c2b91f1d5", digest)
        ActivityScenario.launch(MainActivity::class.java).use {
            compose.onNodeWithText("Third-party licenses").performClick()
            compose.waitUntil(15_000) { compose.onAllNodes(hasScrollToIndexAction()).fetchSemanticsNodes().isNotEmpty() }
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText(library.name))
            compose.onAllNodes(hasText(library.name) and hasClickAction())[0].performClick()
            compose.onNodeWithText(text).assertExists()
            compose.onNodeWithText("OK").performClick()
            assertNull(CredentialStore(context).load())
        }
    }

    @Test
    fun dialogPreservesMultipleLicenseTextsAndLinkedOnlyTerms() {
        val libraries = parseLibraryNotices("""{
            "libraries":[{"uniqueId":"fixture:library","name":"Fixture library","artifactVersion":"1",
                "developers":[],"licenses":["first","second","linked"]}],
            "licenses":{
                "first":{"name":"First license","content":"First complete license text","hash":"first"},
                "second":{"name":"Second license","content":"Second complete license text","hash":"second"},
                "linked":{"name":"Linked terms","url":"https://example.com/terms","hash":"linked"}
            }
        }""")
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity -> activity.setContent {
                PapercupTheme { LibraryNoticesContent(libraries, onBack = {}) }
            } }
            compose.onNodeWithText("Fixture library").performClick()
            compose.onNodeWithText("First complete license text").assertExists()
            compose.onNodeWithText("Second complete license text").assertExists()
            compose.onNode(hasText("Linked terms") and hasAnyAncestor(isDialog())).assertExists()
            compose.onNodeWithText("Open license reference").assertExists()
        }
    }

    @Test
    fun failedResourceDisplaysAnErrorInsteadOfACompletedEmptyList() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity -> activity.setContent {
                PapercupTheme { LibraryNoticesContent(null, failed = true, onBack = {}) }
            } }
            compose.onNodeWithText("Licenses could not be loaded.").assertIsDisplayed()
        }
    }
}

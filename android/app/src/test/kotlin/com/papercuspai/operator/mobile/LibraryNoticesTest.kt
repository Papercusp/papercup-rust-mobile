// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LibraryNoticesTest {
    @Test
    fun collectorSchemaPreservesEveryLicenseAndLinkedReference() {
        val data = parseLibraryNotices("""{
            "libraries": [{"uniqueId":"fixture:library","name":"Fixture library","artifactVersion":"1.2.3",
                "developers":[],"licenses":["first","second","linked"]}],
            "licenses": {
                "first":{"name":"First license","content":"First complete license text","hash":"first"},
                "second":{"name":"Second license","content":"Second complete license text","hash":"second"},
                "linked":{"name":"Linked terms","url":"https://example.com/terms","hash":"linked"}
            }
        }""")
        val library = data.libraries.single()
        assertEquals("1.2.3", library.artifactVersion)
        assertEquals(3, library.licenses.size)
        assertEquals(setOf("First complete license text", "Second complete license text"),
            library.licenses.mapNotNull { it.licenseContent?.takeIf(String::isNotBlank) }.toSet())
        assertTrue(library.licenses.any { it.url == "https://example.com/terms" })
    }

    @Test(expected = IllegalArgumentException::class)
    fun emptyBundledMetadataCannotBecomeASuccessfulBlankScreen() {
        parseLibraryNotices("""{"libraries":[],"licenses":{}}""")
    }

    @Test(expected = Exception::class)
    fun damagedBundledMetadataIsRejected() {
        parseLibraryNotices("not-json")
    }
}

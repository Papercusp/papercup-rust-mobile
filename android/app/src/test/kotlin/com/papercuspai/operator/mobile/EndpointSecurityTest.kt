// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class EndpointSecurityTest {
    @Test
    fun releaseAcceptsHttps() {
        assertNull(EndpointSecurity.rejectionReason("https://api.papercupai.com", false))
    }

    @Test
    fun releaseRejectsCleartextAndMalformedEndpoints() {
        assertNotNull(EndpointSecurity.rejectionReason("http://192.168.1.20:3055", false))
        assertNotNull(EndpointSecurity.rejectionReason("not a url", false))
    }

    @Test
    fun debugAllowsOnlyExplicitLoopbackCleartext() {
        assertNull(EndpointSecurity.rejectionReason("http://10.0.2.2:3055", true))
        assertNull(EndpointSecurity.rejectionReason("http://localhost:3055", true))
        assertNotNull(EndpointSecurity.rejectionReason("http://192.168.1.20:3055", true))
    }
}

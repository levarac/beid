package org.levarac.beid.shared

import kotlin.test.Test
import kotlin.test.assertEquals

class IosSharedModuleIdentityTest {
    @Test
    fun iosReadsTheCommonIdentity() {
        assertEquals("beid-shared", SharedModuleIdentity().value)
    }
}

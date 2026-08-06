package org.levarac.beid.shared

import kotlin.test.Test
import kotlin.test.assertEquals

class AndroidSharedModuleIdentityTest {
    @Test
    fun androidReadsTheCommonIdentity() {
        assertEquals("beid-shared", SharedModuleIdentity().value)
    }
}

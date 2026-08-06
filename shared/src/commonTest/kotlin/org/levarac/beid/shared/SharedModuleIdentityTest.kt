package org.levarac.beid.shared

import kotlin.test.Test
import kotlin.test.assertEquals

class SharedModuleIdentityTest {
    @Test
    fun exposesTheWalkingSkeletonIdentity() {
        assertEquals("beid-shared", SharedModuleIdentity().value)
    }
}

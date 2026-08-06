package org.levarac.beid.shared

import kotlin.test.Test
import kotlin.test.assertEquals

class SharedRuntimeProbeTest {
    @Test
    fun appReadsTheSharedWalkingSkeletonIdentity() {
        assertEquals("beid-shared", SharedRuntimeProbe.identity().value)
    }
}

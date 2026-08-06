package org.levarac.beid.sharedbridge

import kotlin.test.Test
import kotlin.test.assertSame
import org.levarac.beid.shared.SharedModuleIdentity

class SharedRuntimeProbeTest {
    @Test
    fun appResolvesTheIdentityFromTheSharedModule() {
        assertSame(SharedModuleIdentity::class.java, SharedRuntimeProbe.identity()::class.java)
    }
}

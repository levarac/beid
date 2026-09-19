package org.levarac.beid.shared.jointestsupport

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

class RegistryJoinTestSupportTest {
    @Test
    fun failedEventDefinitionResolutionFactoryPreservesFailureEvidence() {
        val resolution = createFailedEventDefinitionResolutionForTesting(
            errorCode = "definition_not_found",
            errorMessage = "no definition was available",
        )

        assertFalse(resolution.isSuccess)
        assertNull(resolution.context)
        assertEquals(0L, resolution.blockNumber)
        assertNull(resolution.blockHashHex)
        assertNull(resolution.definitionHashHex)
        assertEquals("definition_not_found", resolution.errorCode)
        assertEquals("no definition was available", resolution.errorMessage)
    }
}

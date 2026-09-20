package org.levarac.beid.shared.jointestsupport

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RegistryJoinTestSupportTest {
    @Test
    fun successfulEventDefinitionResolutionFactoryPreservesJoinInputs() {
        val eventId = "11".repeat(32)
        val definitionHash = "22".repeat(32)
        val blockHash = "33".repeat(32)

        val resolution = createEventDefinitionResolutionForTesting(
            eventIdHex = "0x$eventId",
            definitionHashHex = definitionHash,
            blockHashHex = "0x$blockHash",
            validFromEpochSeconds = 1_800_000_000L,
            validUntilEpochSeconds = 1_800_003_600L,
            joinMode = org.levarac.parallax.registry.EventJoinMode.GATED,
        )

        val context = requireNotNull(resolution.context)
        val definition = context.definition
        assertTrue(resolution.isSuccess)
        assertEquals(definitionHash, resolution.definitionHashHex)
        assertEquals("0x$eventId", context.eventIdHex)
        assertEquals(definitionHash, context.definitionHashHex)
        assertEquals("0x$eventId", definition.eventIdHex)
        assertEquals(1_800_000_000L, definition.validFrom.value)
        assertEquals(1_800_003_600L, definition.validUntil.value)
        assertEquals(org.levarac.parallax.registry.EventJoinMode.GATED, definition.joinMode)
        assertEquals("0x$blockHash", resolution.blockHashHex)
    }

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

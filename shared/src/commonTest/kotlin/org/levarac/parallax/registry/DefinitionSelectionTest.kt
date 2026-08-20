package org.levarac.parallax.registry

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class DefinitionSelectionTest {
    @Test
    fun validFromBoundaryIsInclusive() {
        val selected = DefinitionSelection.select(deployedContext(), 2_000_000_000L)

        assertEquals(1L, assertNotNull(selected).sequence)
    }

    @Test
    fun validUntilBoundaryIsInclusive() {
        val selected = DefinitionSelection.select(deployedContext(), 2_000_000_100L)

        assertEquals(1L, assertNotNull(selected).sequence)
    }

    @Test
    fun timeBeforeTheFirstWindowSelectsNothing() {
        assertNull(DefinitionSelection.select(deployedContext(), 1_999_999_999L))
    }

    @Test
    fun timeAfterTheLastWindowSelectsNothing() {
        assertNull(DefinitionSelection.select(deployedContext(), 2_000_000_101L))
    }

    @Test
    fun gapBetweenForwardDefinitionsSelectsNothing() {
        val context = twoDefinitionContext()

        assertEquals(1L, assertNotNull(DefinitionSelection.select(context, 110L)).sequence)
        assertNull(DefinitionSelection.select(context, 111L))
        assertNull(DefinitionSelection.select(context, 119L))
        assertEquals(2L, assertNotNull(DefinitionSelection.select(context, 120L)).sequence)
    }

    @Test
    fun laterUseTimeSelectsTheForwardDefinitionWithoutChangingTheContext() {
        val context = twoDefinitionContext()

        val earlier = assertNotNull(DefinitionSelection.select(context, 105L))
        val later = assertNotNull(DefinitionSelection.select(context, 125L))

        assertEquals(1L, earlier.sequence)
        assertEquals(2L, later.sequence)
        assertEquals(2, context.definitionCount)
        assertEquals(2L, context.latestSequence)
    }

    @Test
    fun contextWithoutDefinitionsSelectsNothing() {
        val context = RegistryCborCodec.decode(codecRegistryContextFixture(records = emptyList()))

        assertNull(DefinitionSelection.select(context, 105L))
    }

    private fun deployedContext(): RegistryEventContext =
        RegistryCborCodec.decode(DEPLOYED_ANVIL_CODEC_CBOR_HEX.codecHexToByteArray())

    private fun twoDefinitionContext(): RegistryEventContext {
        val firstDigest = "00".repeat(31) + "a1"
        val secondDigest = "00".repeat(31) + "a2"
        return RegistryCborCodec.decode(
            codecRegistryContextFixture(
                records = listOf(
                    CodecDefinitionFixture(
                        sequence = 1L,
                        previousDefinitionDigestHex = CODEC_ZERO_DIGEST_HEX,
                        definitionDigestHex = firstDigest,
                        validFrom = 100L,
                        validUntil = 110L,
                        anchoredAt = 90L,
                    ),
                    CodecDefinitionFixture(
                        sequence = 2L,
                        previousDefinitionDigestHex = firstDigest,
                        definitionDigestHex = secondDigest,
                        validFrom = 120L,
                        validUntil = 130L,
                        anchoredAt = 115L,
                    ),
                ),
                registeredAt = 50L,
            ),
        )
    }
}

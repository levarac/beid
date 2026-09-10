package org.levarac.parallax.venue

import org.levarac.parallax.observation.ByteString32
import org.levarac.parallax.observation.ImmutableBytes
import org.levarac.parallax.registry.Address20
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/** Pins the bounded type independently of the decoder that normally constructs it. */
class VenueBundleBoundsTest {
    @Test
    fun anInternalCallerCannotConstructAnOutOfBoundsBundle() {
        assertFailsWith<IllegalArgumentException> { construct(emptyList()) }
        assertFailsWith<IllegalArgumentException> { construct(List(513) { ByteArray(199) }) }
        assertFailsWith<IllegalArgumentException> { construct(listOf(ByteArray(198))) }
        assertFailsWith<IllegalArgumentException> { construct(listOf(ByteArray(509))) }
        assertEquals(1, construct(listOf(ByteArray(199))).envelopeCount)
        assertEquals(512, construct(List(512) { ByteArray(508) }).envelopeCount)
    }

    @Test
    fun constructorDoesNotRetainTheCallersMutableCollectionOrArrays() {
        val bytes = ByteArray(199) { 6 }
        val envelopes = mutableListOf(bytes)
        val bundle = construct(envelopes)
        bytes.fill(0)
        envelopes.clear()
        assertEquals(1, bundle.envelopeCount)
        assertContentEquals(ByteArray(199) { 6 }, bundle.envelopeAt(0))
    }

    private fun construct(envelopes: List<ByteArray>) = VenueBundle(
        chainId = 1,
        eventRegistry = Address20(ByteArray(20)),
        eventDefinitionRegistry = Address20(ByteArray(20)),
        eventId = ByteString32(ByteArray(32)),
        definitionSequence = 1,
        definitionDigest = ByteString32(ByteArray(32)),
        signedEventDefinition = ImmutableBytes(byteArrayOf(1)),
        eventKeySet = ImmutableBytes(byteArrayOf(1)),
        envelopes = envelopes,
        bundleDigest = ByteString32(ByteArray(32)),
    )
}

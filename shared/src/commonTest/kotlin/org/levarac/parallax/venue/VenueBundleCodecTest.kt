package org.levarac.parallax.venue

import org.levarac.parallax.observation.CanonicalCbor
import org.levarac.parallax.registry.EventDefinitionCborCodec.StrictCborReader
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/** Format-only vectors; decoding alone never authenticates an envelope or permits serving. */
class VenueBundleCodecTest {
    @Test
    fun decodesEveryBundleFieldWithoutChangingSignedBytes() {
        val bundle = assertNotNull(decodeVenueBundle(bundleBytes()))
        assertEquals(1L, bundle.chainId)
        assertEquals(1L, bundle.definitionSequence)
        assertContentEquals(ByteArray(20) { 1 }, bundle.eventRegistry.toByteArray())
        assertContentEquals(ByteArray(20) { 2 }, bundle.eventDefinitionRegistry.toByteArray())
        assertContentEquals(ByteArray(32) { 3 }, bundle.eventId.toByteArray())
        assertContentEquals(ByteArray(32) { 4 }, bundle.definitionDigest.toByteArray())
        assertContentEquals(byteArrayOf(0x42, 1), bundle.signedEventDefinition.toByteArray())
        assertContentEquals(byteArrayOf(0x43, 2), bundle.eventKeySet.toByteArray())
        assertEquals(1, bundle.envelopeCount)
        assertContentEquals(ByteArray(199) { 6 }, bundle.envelopeAt(0))
        assertNull(bundle.envelopeAt(1))
    }

    @Test
    fun outerDigestMatchesAnIndependentPythonHashlibVector() {
        // Independently encoded with Python's bytes/int primitives, then hashlib.sha256.
        assertEquals(
            "2ae3f51a85747f845bf7760cf95927b627453394bff4bb6e9cdaf3f9ba85d373",
            assertNotNull(decodeVenueBundle(bundleBytes())).bundleDigest.toString(),
        )
    }

    @Test
    fun decodedBytesAreDefensiveCopies() {
        val bytes = bundleBytes()
        val bundle = assertNotNull(decodeVenueBundle(bytes))
        bytes.fill(0)
        assertNotNull(bundle.envelopeAt(0)).fill(0)
        bundle.eventId.toByteArray().fill(0)
        assertContentEquals(ByteArray(199) { 6 }, bundle.envelopeAt(0))
        assertContentEquals(ByteArray(32) { 3 }, bundle.eventId.toByteArray())
    }

    @Test
    fun rejectsUnsupportedVersionAndSequenceZero() {
        assertNull(decodeVenueBundle(bundleBytes(version = 2)))
        assertNull(decodeVenueBundle(bundleBytes(sequence = 0)))
        assertNull(decodeVenueHandoff(handoffBytes().also { it[2] = 2 }))
    }

    @Test
    fun acceptsTheProtocolIntegerMaximumButNotTheNextInteger() {
        assertNotNull(decodeVenueBundle(bundleBytes(chainId = 9_007_199_254_740_991L)))
        assertNull(decodeVenueBundle(bundleBytes(chainId = 9_007_199_254_740_992L)))
        assertNull(decodeVenueBundle(bundleBytes(sequence = 9_007_199_254_740_992L)))
    }

    @Test
    fun rejectsNonminimalIntegersAndIndefiniteMaps() {
        val canonical = bundleBytes()
        val nonminimal = canonical.take(2).toByteArray() + byteArrayOf(0x18, 1) + canonical.drop(3)
        assertNull(decodeVenueBundle(nonminimal))
        assertNull(decodeVenueBundle(byteArrayOf(0xbf.toByte()) + canonical.drop(1) + byteArrayOf(0xff.toByte())))
    }

    @Test
    fun rejectsUnknownMissingDuplicateAndOutOfOrderKeys() {
        val canonical = bundleBytes()
        assertNull(decodeVenueBundle(canonical.copyOf().also { it[0] = 0xa9.toByte() }))
        assertNull(decodeVenueBundle(canonical.copyOf().also { it[0] = 0xab.toByte() }))
        assertNull(decodeVenueBundle(canonical.copyOf().also { it[3] = 1 }))
        assertNull(decodeVenueBundle(canonical.copyOf().also { it[1] = 2 }))
    }

    @Test
    fun rejectsEveryTruncatedPrefixAndTrailingBytes() {
        val canonical = bundleBytes()
        for (size in canonical.indices) assertNull(decodeVenueBundle(canonical.copyOf(size)), "prefix $size")
        assertNull(decodeVenueBundle(canonical + byteArrayOf(0)))
        val handoff = handoffBytes()
        for (size in handoff.indices) assertNull(decodeVenueHandoff(handoff.copyOf(size)), "handoff prefix $size")
        assertNull(decodeVenueHandoff(handoff + byteArrayOf(0)))
    }

    @Test
    fun enforcesEnvelopeCountAndByteBoundsLiterally() {
        assertNull(decodeVenueBundle(bundleBytes(count = 0)))
        assertNotNull(decodeVenueBundle(bundleBytes(count = 512)))
        assertNull(decodeVenueBundle(bundleBytes(count = 513)))
        assertNull(decodeVenueBundle(bundleBytes(envelopeSize = 198)))
        assertNotNull(decodeVenueBundle(bundleBytes(envelopeSize = 508)))
        assertNull(decodeVenueBundle(bundleBytes(envelopeSize = 509)))
    }

    @Test
    fun envelopeReaderEnforcesCountBoundsWithoutTheBundleConstructor() {
        // Complete, small arrays ensure a missing guard cannot be masked by
        // truncated input or VenueBundle's duplicate constructor validation.
        for (count in listOf(0, 513)) {
            assertFailsWith<IllegalArgumentException>("count $count") {
                readBoundedEnvelopes(StrictCborReader(envelopeArrayBytes(count, 199)))
            }
        }
        for (count in listOf(1, 512)) {
            val reader = StrictCborReader(envelopeArrayBytes(count, 199))
            val envelopes = readBoundedEnvelopes(reader)
            reader.requireFinished()
            assertEquals(count, envelopes.size)
            for (envelope in envelopes) assertContentEquals(ByteArray(199) { 6 }, envelope)
        }
    }

    @Test
    fun envelopeReaderEnforcesByteBoundsWithoutTheBundleConstructor() {
        for (size in listOf(198, 509)) {
            assertFailsWith<IllegalArgumentException>("byte length $size") {
                readBoundedEnvelopes(StrictCborReader(envelopeArrayBytes(1, size)))
            }
        }
        for (size in listOf(199, 508)) {
            val reader = StrictCborReader(envelopeArrayBytes(1, size))
            val envelopes = readBoundedEnvelopes(reader)
            reader.requireFinished()
            assertEquals(1, envelopes.size)
            assertContentEquals(ByteArray(size) { 6 }, envelopes.single())
        }
    }

    @Test
    fun enforcesAddressAndDigestLengths() {
        for (size in listOf(0, 19, 21)) assertNull(decodeVenueBundle(bundleBytes(addressSize = size)))
        for (size in listOf(0, 31, 33)) assertNull(decodeVenueBundle(bundleBytes(eventIdSize = size)))
    }

    @Test
    fun handoffAllowsExactlyTheSixRequiredFieldsAndOneOptionalUrl() {
        val handoff = assertNotNull(decodeVenueHandoff(handoffBytes()))
        assertEquals(1L, handoff.chainId)
        assertNull(handoff.bundleUrl)
        assertContentEquals(ByteArray(32) { 3 }, handoff.eventId.toByteArray())
        assertContentEquals(ByteArray(20) { 1 }, handoff.eventRegistry.toByteArray())
        assertContentEquals(ByteArray(20) { 2 }, handoff.eventDefinitionRegistry.toByteArray())
        assertContentEquals(ByteArray(32) { 7 }, handoff.bundleDigest.toByteArray())
        val withUrl = assertNotNull(decodeVenueHandoff(handoffBytes(url = "https://venue.example/bundle")))
        assertEquals("https://venue.example/bundle", withUrl.bundleUrl)
        assertNull(decodeVenueHandoff(handoffBytes().also { it[0] = 0xa5.toByte() }))
        assertNull(decodeVenueHandoff(handoffBytes().also { it[0] = 0xa8.toByte() }))
    }

    @Test
    fun handoffRequiresAnAbsoluteUriAndBoundsItsUtf8Bytes() {
        assertNull(decodeVenueHandoff(handoffBytes(url = "")))
        assertNull(decodeVenueHandoff(handoffBytes(url = "/relative")))
        assertNull(decodeVenueHandoff(handoffBytes(url = "not a uri")))
        assertNotNull(decodeVenueHandoff(handoffBytes(url = "https://v/" + "a".repeat(2038))))
        assertNull(decodeVenueHandoff(handoffBytes(url = "https://v/" + "a".repeat(2039))))
    }

    @Test
    fun linkCarriesOnlyTheHandoffAndIsNeverTrustedAsTheBundle() {
        val link = "https://handoff.example/#$HANDOFF_BASE64URL"
        val handoff = assertNotNull(decodeVenueHandoffLink(link))
        assertContentEquals(ByteArray(32) { 3 }, handoff.eventId.toByteArray())
        assertNull(handoff.bundleUrl)
        assertNull(decodeVenueHandoffLink("https://handoff.example/"))
        assertNull(decodeVenueHandoffLink("relative#$HANDOFF_BASE64URL"))
        assertNull(decodeVenueHandoffLink("https://handoff.example/#%%%"))
    }

    @Test
    fun rejectsOversizeWholeInputs() {
        assertNull(decodeVenueBundle(ByteArray(1_048_577)))
        assertNull(decodeVenueHandoff(ByteArray(4097)))
    }

    private fun envelopeArrayBytes(count: Int, size: Int): ByteArray =
        CanonicalCbor.encode(CanonicalCbor.array(List(count) { bytes(ByteArray(size) { 6 }) }))

    private fun bundleBytes(
        version: Long = 1,
        chainId: Long = 1,
        sequence: Long = 1,
        count: Int = 1,
        envelopeSize: Int = 199,
        addressSize: Int = 20,
        eventIdSize: Int = 32,
    ): ByteArray = CanonicalCbor.encode(CanonicalCbor.map(
        uint(1) to uint(version), uint(2) to uint(chainId),
        uint(3) to bytes(ByteArray(addressSize) { 1 }), uint(4) to bytes(ByteArray(20) { 2 }),
        uint(5) to bytes(ByteArray(eventIdSize) { 3 }), uint(6) to uint(sequence),
        uint(7) to bytes(ByteArray(32) { 4 }), uint(8) to bytes(byteArrayOf(0x42, 1)),
        uint(9) to bytes(byteArrayOf(0x43, 2)),
        uint(10) to CanonicalCbor.array(List(count) { bytes(ByteArray(envelopeSize) { 6 }) }),
    ))

    private fun handoffBytes(url: String? = null): ByteArray {
        val fields = mutableListOf(
            uint(1) to uint(1), uint(2) to bytes(ByteArray(32) { 3 }), uint(3) to uint(1),
            uint(4) to bytes(ByteArray(20) { 1 }), uint(5) to bytes(ByteArray(20) { 2 }),
            uint(6) to bytes(ByteArray(32) { 7 }),
        )
        if (url != null) fields += uint(7) to CanonicalCbor.text(url)
        return CanonicalCbor.encode(CanonicalCbor.map(*fields.toTypedArray()))
    }

    private fun uint(value: Long) = CanonicalCbor.uint(value)
    private fun bytes(value: ByteArray) = CanonicalCbor.bytes(value)

    private companion object {
        const val HANDOFF_BASE64URL = "pgEBAlggAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAQRUAQEBAQEBAQEBAQEBAQEBAQEBAQEFVAICAgICAgICAgICAgICAgICAgICBlggBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc"
    }
}

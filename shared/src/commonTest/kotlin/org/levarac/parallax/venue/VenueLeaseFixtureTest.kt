package org.levarac.parallax.venue

import kotlinx.serialization.json.jsonObject
import org.levarac.parallax.observation.readVectorResource
import org.levarac.parallax.registry.DefinitionDecodeError
import org.levarac.parallax.registry.DefinitionDecodeException
import org.levarac.parallax.registry.EventDefinitionCborCodec
import org.levarac.parallax.registry.EventJoinMode
import org.levarac.parallax.registry.Sha256
import org.levarac.parallax.registry.decodeHex
import org.levarac.parallax.registry.requiredLong
import org.levarac.parallax.registry.requiredString
import org.levarac.parallax.registry.toPrefixedHex
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull

class VenueLeaseFixtureTest {
    @Test
    fun bothRealSignedBundlesAndTheirHandoffsDecodeWithoutChangingBytes() {
        val fixture = venueLeaseVector()
        for (caseName in listOf("authorityDirect", "delegate")) {
            val case = fixture.getValue(caseName).jsonObject
            val bundle = assertNotNull(decodeVenueBundle(case.requiredString("bundleHex").decodeHex()))
            val handoff = assertNotNull(decodeVenueHandoff(case.requiredString("handoffHex").decodeHex()))
            assertEquals(1, bundle.envelopeCount)
            assertEquals(case.requiredString("bundleDigestHex"), bundle.bundleDigest.toString())
            assertEquals(bundle.bundleDigest, handoff.bundleDigest)
            assertEquals(bundle.eventId, handoff.eventId)
            assertContentEquals(case.requiredString("signedEnvelopeHex").decodeHex(), bundle.envelopeAt(0))
            assertContentEquals(fixture.requiredString("signedEventDefinitionHex").decodeHex(), bundle.signedEventDefinition.toByteArray())
            assertContentEquals(fixture.requiredString("eventKeySetHex").decodeHex(), bundle.eventKeySet.toByteArray())
        }
    }

    @Test
    fun envelopesRemainThePinnedBarnardBytesRatherThanALocalIssuer() {
        val source = readVectorResource("vectors/upstream/barnard-b005-envelope-v2.txt")
        assertEquals(
            "4e037cc61afbe40985b019097b0197dffb91e4ebc2d6ee5c19bb2b7d13df2dd1",
            Sha256.digest(source.encodeToByteArray()).toPrefixedHex().removePrefix("0x"),
        )
        val fields = source.lineSequence().filter { it.isNotBlank() && !it.startsWith("#") }
            .associate { it.substringBefore('=') to it.substringAfter('=') }
        val fixture = venueLeaseVector()
        assertEquals(fields.getValue("v1_envelope"), fixture.getValue("authorityDirect").jsonObject.requiredString("signedEnvelopeHex"))
        assertEquals(fields.getValue("v2_envelope"), fixture.getValue("delegate").jsonObject.requiredString("signedEnvelopeHex"))
        // The source envelope expires before its definition ends. This fixture can prove a
        // current lease, and deliberately cannot prove the phase-2 full-coverage claim.
        assertEquals(6_000_002L, fixture.requiredLong("signedRelayExpiresAtEnin"))
        assertEquals(6_000_010L, fixture.requiredLong("signedValidThroughEnin"))
    }

    @Test
    fun parallaxSignedOpenDefinitionAlsoVerifiesInTheSharedImplementation() {
        val fixture = venueLeaseVector()
        val verified = verify(fixture.requiredString("signedEventDefinitionHex").decodeHex())
        assertEquals(EventJoinMode.OPEN, verified.definition.joinMode)
        assertEquals("9adc61d60dda843e", verified.definition.eventCodeHashHex)
        assertEquals(1_799_997_000L, verified.definition.validFrom.value)
        assertEquals(1_800_003_299L, verified.definition.validUntil.value)
    }

    @Test
    fun oneByteSignatureMutationIsRejectedByTheSharedDefinitionVerifier() {
        val signed = venueLeaseVector().requiredString("signedEventDefinitionHex").decodeHex()
        signed[signed.lastIndex] = (signed.last().toInt() xor 1).toByte()
        val failure = assertFailsWith<DefinitionDecodeException> { verify(signed) }
        assertEquals(DefinitionDecodeError.INVALID_SIGNATURE, failure.reason)
    }

    private fun verify(signed: ByteArray): EventDefinitionCborCodec.VerifiedDefinition {
        val fixture = venueLeaseVector()
        return EventDefinitionCborCodec.verify(
            signedBytes = signed,
            encodedKeySet = fixture.requiredString("eventKeySetHex").decodeHex(),
            eventId = fixture.getValue("registration").jsonObject.requiredString("eventIdHex").decodeHex(),
            registration = fixture.venueRegistration(),
            record = fixture.venueDefinitionRecord(),
            at = fixture.requiredLong("currentEpochSeconds"),
        )
    }
}

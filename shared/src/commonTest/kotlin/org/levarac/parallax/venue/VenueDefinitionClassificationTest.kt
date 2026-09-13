package org.levarac.parallax.venue

import org.levarac.parallax.registry.GATED_DEFINITION_DIGEST_HEX
import org.levarac.parallax.registry.GATED_SIGNED_DEFINITION_HEX
import org.levarac.parallax.registry.OPEN_DEFINITION_DIGEST_HEX
import org.levarac.parallax.registry.OPEN_SIGNED_DEFINITION_HEX
import org.levarac.parallax.registry.EventDefinition
import org.levarac.parallax.registry.EventDefinitionCborCodec
import org.levarac.parallax.registry.EventJoinMode
import org.levarac.parallax.registry.anchorRegistration
import org.levarac.parallax.registry.definitionRecord
import org.levarac.parallax.registry.readEventDefinitionVector
import org.levarac.parallax.registry.requiredString
import org.levarac.parallax.registry.vectorEventId
import org.levarac.parallax.registry.vectorHexBytes
import org.levarac.parallax.registry.verifyExtendedDefinition
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Every case here is classified from REAL codec output — a signed definition
 * put through `EventDefinitionCborCodec.verify` — rather than from a
 * hand-assembled [EventDefinition]. The point of the classification is to
 * describe what the codec actually produces, so a hand-built input could
 * assert a shape the codec never emits and still pass.
 */
class VenueDefinitionClassificationTest {

    private fun definition(signedHex: String, digestHex: String): EventDefinition =
        verifyExtendedDefinition(
            readEventDefinitionVector("vectors/positive/event-definition-v1.json"),
            signedHex,
            digestHex,
        ).definition

    /**
     * A gated definition classifies as needing a hash from outside itself, and
     * is distinguishable from a definition that merely has no usable join
     * declaration.
     *
     * The codec forbids a gated definition from carrying an `eventCodeHash`
     * (`EventDefinitionCborCodec`, and `gatedDefinitionPublishesSignedModeWithoutAnEventCodeHash`
     * asserts it on these same bytes), so before this function existed the two
     * were the same observation. Reverting [classifyVenueDefinition] to that
     * previous rule — return OPEN when a well-formed 8-byte hash is present,
     * otherwise NO_USABLE_JOIN_DECLARATION, never looking at the join mode —
     * turns this RED.
     */
    @Test
    fun gatedDefinitionNeedsAHashFromOutsideItselfRatherThanHavingNoJoinDeclaration() {
        val gated = definition(GATED_SIGNED_DEFINITION_HEX, GATED_DEFINITION_DIGEST_HEX)
        assertEquals(EventJoinMode.GATED, gated.joinMode)
        assertEquals(null, gated.eventCodeHashHex)

        assertEquals(
            VenueDefinitionClassification.GATED_REQUIRES_EXTERNAL_HASH,
            classifyVenueDefinition(gated),
        )
    }

    @Test
    fun openDefinitionWithTheCanonicalHashIsClassifiedAsServableFromTheDefinitionAlone() {
        val open = definition(OPEN_SIGNED_DEFINITION_HEX, OPEN_DEFINITION_DIGEST_HEX)
        assertEquals(EventJoinMode.OPEN, open.joinMode)

        assertEquals(
            VenueDefinitionClassification.OPEN_WITH_EVENT_CODE_HASH,
            classifyVenueDefinition(open),
        )
    }

    /**
     * A legacy key-1-through-13 definition carries no join mode at all, which
     * is the reachable half of [VenueDefinitionClassification.NO_USABLE_JOIN_DECLARATION].
     * The other half — an open definition whose hash is absent or the wrong
     * length — is rejected by the codec before trust, so it cannot be built
     * here; the classification still handles it fail-closed rather than
     * assuming it impossible.
     */
    @Test
    fun legacyDefinitionWithoutAJoinModeHasNoUsableJoinDeclaration() {
        val vector = readEventDefinitionVector("vectors/positive/event-definition-v1.json")
        val legacy = EventDefinitionCborCodec.verify(
            signedBytes = vector.requiredString("signedEventDefinitionHex").vectorHexBytes(),
            encodedKeySet = vector.requiredString("eventKeySetHex").vectorHexBytes(),
            eventId = vector.vectorEventId(),
            registration = vector.anchorRegistration(),
            record = vector.definitionRecord(),
            at = vector.definitionRecord().validFrom,
        ).definition
        assertEquals(null, legacy.joinMode)

        assertEquals(
            VenueDefinitionClassification.NO_USABLE_JOIN_DECLARATION,
            classifyVenueDefinition(legacy),
        )
    }
}

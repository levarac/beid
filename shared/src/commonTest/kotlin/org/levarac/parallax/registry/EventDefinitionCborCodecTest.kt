package org.levarac.parallax.registry

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import org.levarac.parallax.observation.readVectorResource

class EventDefinitionCborCodecTest {
    @Test
    fun committedVectorsMatchThePinnedParallaxSourceChecksums() {
        assertEquals(
            "db889e0a47557ce0fa3ca0ea1b04bf83295c9def70d89e2b53462f7c8898dc00",
            Sha256.digest(
                readVectorResource("vectors/positive/event-definition-v1.json").encodeToByteArray(),
            ).toHexWithoutPrefix(),
        )
        assertEquals(
            "fab1ef02cd5403ef785203a75973159820bf7e1050d2325777913a5a16f03d0d",
            Sha256.digest(
                readVectorResource("vectors/negative/event-definition-v1.json").encodeToByteArray(),
            ).toHexWithoutPrefix(),
        )
        assertEquals(
            "e1fa6c37c0154b495f7d43fa1098ee79ea837e70652e6aef2bede68d68a82326",
            Sha256.digest(
                readVectorResource("canonical/event-definition-v1.cddl").encodeToByteArray(),
            ).toHexWithoutPrefix(),
        )
    }

    @Test
    fun positiveVectorDecodesTheExactCanonicalBytesAndVerifiesAllBindings() {
        val vector = readEventDefinitionVector("vectors/positive/event-definition-v1.json")
        val signed = vector.requiredString("signedEventDefinitionHex").vectorHexBytes()
        val keySet = vector.requiredString("eventKeySetHex").vectorHexBytes()
        val eventId = vector.vectorEventId()

        assertContentEquals(
            vector.requiredString("signedEventDefinitionHex").vectorHexBytes(),
            signed,
        )
        assertEquals(
            "0x" + vector.requiredString("keySetDigestHex"),
            EventDefinitionCborCodec.eventKeySetDigest(keySet).toPrefixedHex(),
        )
        assertEquals(
            "0x" + vector.requiredString("eventDefinitionDigestHex"),
            EventDefinitionCborCodec.eventDefinitionDigest(signed).toPrefixedHex(),
        )

        val verified = EventDefinitionCborCodec.verify(
            signedBytes = signed,
            encodedKeySet = keySet,
            eventId = eventId,
            registration = vector.anchorRegistration(),
            record = vector.definitionRecord(),
            at = vector.definitionRecord().validFrom,
        )
        val definition = verified.definition

        assertEquals(1, definition.version)
        assertContentEquals(eventId, definition.eventId.toByteArray())
        assertEquals("1111111111111111111111111111111111111111", definition.registrar.toByteArray().toHexWithoutPrefix())
        assertEquals("2222222222222222222222222222222222222222", definition.anchorOperator.toByteArray().toHexWithoutPrefix())
        assertEquals("3333333333333333333333333333333333333333333333333333333333333333", definition.nonce.toByteArray().toHexWithoutPrefix())
        assertEquals("02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5", definition.receiptPublicKey.toByteArray().toHexWithoutPrefix())
        assertEquals("50d8f3689f95e95c30be32dc4e516460dff139c088ab1117af0c104188252949", definition.operatorId.toByteArray().toHexWithoutPrefix())
        assertEquals("https://operator.example/v1/observations", definition.submissionEndpoint)
        assertEquals(1L, definition.sequence.value)
        assertEquals(1_799_999_900L, definition.validFrom.value)
        assertEquals(1_800_086_400L, definition.validUntil.value)
        assertEquals(1, verified.keySet.authorityKeyCount)
        assertEquals(
            "02f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9",
            definition.authorityPublicKey.toByteArray().toHexWithoutPrefix(),
        )
    }

    @Test
    fun negativeVectorSubstitutedKeySetIsAtypedKeySetDigestRejection() {
        val vector = readEventDefinitionVector("vectors/negative/event-definition-v1.json")
        val error = assertFailsWith<DefinitionDecodeException> {
            EventDefinitionCborCodec.verify(
                signedBytes = vector.requiredString("signedEventDefinitionHex").vectorHexBytes(),
                encodedKeySet = vector.requiredString("substitutedEventKeySetHex").vectorHexBytes(),
                eventId = vector.vectorEventId(),
                registration = vector.anchorRegistration(),
                record = vector.definitionRecord(),
                at = vector.definitionRecord().validFrom,
            )
        }
        assertEquals(DefinitionDecodeError.KEY_SET_DIGEST_MISMATCH, error.reason)
    }

    @Test
    fun negativeVectorAnchorAtValidityStartIsAtypedValidityRejection() {
        val vector = readEventDefinitionVector("vectors/negative/event-definition-v1.json")
        val error = assertFailsWith<DefinitionDecodeException> {
            EventDefinitionCborCodec.verify(
                signedBytes = vector.requiredString("signedEventDefinitionHex").vectorHexBytes(),
                encodedKeySet = readEventDefinitionVector("vectors/positive/event-definition-v1.json")
                    .requiredString("eventKeySetHex").vectorHexBytes(),
                eventId = vector.vectorEventId(),
                registration = vector.anchorRegistration(),
                record = vector.definitionRecord("sameTimeDefinitionAnchor"),
                at = vector.definitionRecord().validFrom,
            )
        }
        assertEquals(DefinitionDecodeError.INVALID_VALIDITY, error.reason)
    }

    @Test
    fun trailingBytesAreRejectedBeforeAnyAuthorityVerification() {
        val vector = readEventDefinitionVector("vectors/positive/event-definition-v1.json")
        val error = assertFailsWith<DefinitionDecodeException> {
            EventDefinitionCborCodec.verify(
                signedBytes = vector.requiredString("signedEventDefinitionHex").vectorHexBytes() + byteArrayOf(0),
                encodedKeySet = vector.requiredString("eventKeySetHex").vectorHexBytes(),
                eventId = vector.vectorEventId(),
                registration = vector.anchorRegistration(),
                record = vector.definitionRecord(),
                at = vector.definitionRecord().validFrom,
            )
        }
        assertEquals(DefinitionDecodeError.MALFORMED, error.reason)
    }
}

private fun ByteArray.toHexWithoutPrefix(): String = buildString(size * 2) {
    for (byte in this@toHexWithoutPrefix) {
        val value = byte.toInt() and 0xff
        append("0123456789abcdef"[value ushr 4])
        append("0123456789abcdef"[value and 0x0f])
    }
}

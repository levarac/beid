package org.levarac.parallax.registry

import org.levarac.parallax.observation.CanonicalCbor
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

    @Test
    fun directNegativeInputsExposeTypedReasonsForEachVerificationBoundary() {
        val vector = readEventDefinitionVector("vectors/positive/event-definition-v1.json")
        val signed = vector.requiredString("signedEventDefinitionHex").vectorHexBytes()
        val keySet = vector.requiredString("eventKeySetHex").vectorHexBytes()

        assertDecodeReason(
            signed = signed.copyOf().also { bytes ->
                bytes[bytes.lastIndex] = (bytes[bytes.lastIndex].toInt() xor 1).toByte()
            },
            keySet = keySet,
            vector = vector,
            expected = DefinitionDecodeError.INVALID_SIGNATURE,
        )
        assertDecodeReason(
            signed = signed.copyOf().also { bytes ->
                bytes[bytes.size - 32] = 0x80.toByte()
            },
            keySet = keySet,
            vector = vector,
            expected = DefinitionDecodeError.INVALID_SIGNATURE,
        )
        assertDecodeReason(
            signed = signed.copyOf().also { bytes ->
                assertEquals(0x2e.toByte(), bytes[7])
                bytes[7] = 0x2d.toByte()
            },
            keySet = keySet,
            vector = vector,
            expected = DefinitionDecodeError.INVALID_COSE,
        )
        assertDecodeReason(
            signed = mutateProtectedContentType(signed),
            keySet = keySet,
            vector = vector,
            expected = DefinitionDecodeError.INVALID_COSE,
        )
        assertDecodeReason(
            signed = mutatePayloadByteString(signed, field = 10),
            keySet = keySet,
            vector = vector,
            expected = DefinitionDecodeError.OPERATOR_ID_MISMATCH,
        )
        assertDecodeReason(
            signed = mutatePayloadByteString(signed, field = 2),
            keySet = keySet,
            vector = vector,
            expected = DefinitionDecodeError.EVENT_ID_MISMATCH,
        )
        assertDecodeReason(
            signed = signed,
            keySet = readEventDefinitionVector("vectors/negative/event-definition-v1.json")
                .requiredString("substitutedEventKeySetHex")
                .vectorHexBytes(),
            vector = vector,
            expected = DefinitionDecodeError.KEY_SET_DIGEST_MISMATCH,
        )
    }

    @Test
    fun submissionEndpointRejectsWhatTheReferenceUrlParserRejects() {
        val vector = readEventDefinitionVector("vectors/positive/event-definition-v1.json")
        val keySet = vector.requiredString("eventKeySetHex").vectorHexBytes()
        listOf(
            "https://[not-ipv6]/submit",
            "https://[2001:db8::1/submit",
            "https://[2001:db8::1]]/submit",
            "https://[1.2.3.4::]/submit",
            "https://[2001:db8::1::2]/submit",
            "https://[2001:db8:0:0:0:0:0:0:1]/submit",
            "https://[2001:db8::gg]/submit",
            "https://%zz/submit",
            "https://%2F/submit",
            "https://%00/submit",
            "https://%0B/submit",
            "https://%0C/submit",
            "https://%25/submit",
            "https://%7F/submit",
            "https://%23/submit",
            "https://%40/submit",
            "https://%5C/submit",
            "https://user:pass@operator.example/submit",
            "http://operator.example/submit",
            "https://operator.example:65536/submit",
            "https://operator.example:abc/submit",
        ).forEach { endpoint ->
            assertDecodeReason(
                signed = signedDefinitionWithEndpoint(vector, endpoint),
                keySet = keySet,
                vector = vector,
                expected = DefinitionDecodeError.INVALID_ENDPOINT,
            )
        }
    }

    @Test
    fun harmlessPercentDecodedHostCharactersReachSignatureVerification() {
        val vector = readEventDefinitionVector("vectors/positive/event-definition-v1.json")
        val keySet = vector.requiredString("eventKeySetHex").vectorHexBytes()

        assertDecodeReason(
            signed = signedDefinitionWithEndpoint(vector, "https://operator%2D.example/submit"),
            keySet = keySet,
            vector = vector,
            expected = DefinitionDecodeError.INVALID_SIGNATURE,
        )
    }

    @Test
    fun validBracketedIpv6HostsReachSignatureVerification() {
        val vector = readEventDefinitionVector("vectors/positive/event-definition-v1.json")
        val keySet = vector.requiredString("eventKeySetHex").vectorHexBytes()
        listOf(
            "https://[2001:0db8:0000:0000:0000:ff00:0042:8329]/submit",
            "https://[2001:db8::1]/submit",
            "https://[::ffff:192.0.2.128]/submit",
        ).forEach { endpoint ->
            assertDecodeReason(
                signed = signedDefinitionWithEndpoint(vector, endpoint),
                keySet = keySet,
                vector = vector,
                expected = DefinitionDecodeError.INVALID_SIGNATURE,
            )
        }
    }

    private fun assertDecodeReason(
        signed: ByteArray,
        keySet: ByteArray,
        vector: kotlinx.serialization.json.JsonObject,
        expected: DefinitionDecodeError,
    ) {
        val error = assertFailsWith<DefinitionDecodeException> {
            EventDefinitionCborCodec.verify(
                signedBytes = signed,
                encodedKeySet = keySet,
                eventId = vector.vectorEventId(),
                registration = vector.anchorRegistration(),
                record = vector.definitionRecord(),
                at = vector.definitionRecord().validFrom,
            )
        }
        assertEquals(expected, error.reason)
    }

    private fun mutatePayloadByteString(signed: ByteArray, field: Int): ByteArray {
        val result = signed.copyOf()
        val protectedLength = result[3].toInt() and 0xff
        var payloadLengthOffset = 4 + protectedLength + 1
        assertEquals(0x59.toByte(), result[payloadLengthOffset])
        val payloadLength = ((result[payloadLengthOffset + 1].toInt() and 0xff) shl 8) or
            (result[payloadLengthOffset + 2].toInt() and 0xff)
        val payloadStart = payloadLengthOffset + 3
        val payloadEnd = payloadStart + payloadLength
        val prefix = byteArrayOf(field.toByte(), 0x58, 0x20)
        var valueStart = -1
        for (offset in payloadStart until payloadEnd - prefix.size) {
            if (result.copyOfRange(offset, offset + prefix.size).contentEquals(prefix)) {
                valueStart = offset + prefix.size
                break
            }
        }
        require(valueStart >= 0) { "field $field was not found in the canonical vector" }
        result[valueStart] = (result[valueStart].toInt() xor 1).toByte()
        return result
    }

    private fun mutateProtectedContentType(signed: ByteArray): ByteArray {
        val result = signed.copyOf()
        val protectedLength = result[3].toInt() and 0xff
        val protectedStart = 4
        val protectedEnd = protectedStart + protectedLength
        val contentType = "application/vnd.levarac.event-definition+cbor".encodeToByteArray()
        var valueStart = -1
        for (offset in protectedStart..(protectedEnd - contentType.size)) {
            if (result.copyOfRange(offset, offset + contentType.size).contentEquals(contentType)) {
                valueStart = offset
                break
            }
        }
        require(valueStart >= 0) { "protected content-type was not found in the canonical vector" }
        result[valueStart] = 'x'.code.toByte()
        return result
    }

    private fun signedDefinitionWithEndpoint(
        vector: kotlinx.serialization.json.JsonObject,
        endpoint: String,
    ): ByteArray {
        val original = vector.requiredString("signedEventDefinitionHex").vectorHexBytes()
        val registration = vector.anchorRegistration()
        val payload = CanonicalCbor.encode(
            CanonicalCbor.map(
                CanonicalCbor.uint(1) to CanonicalCbor.uint(1),
                CanonicalCbor.uint(2) to CanonicalCbor.bytes(vector.vectorEventId()),
                CanonicalCbor.uint(3) to CanonicalCbor.bytes(registration.registrarHex.decodeHex(20)),
                CanonicalCbor.uint(4) to CanonicalCbor.bytes(registration.operatorHex.decodeHex(20)),
                CanonicalCbor.uint(5) to CanonicalCbor.bytes("33".repeat(32).decodeHex()),
                CanonicalCbor.uint(6) to CanonicalCbor.bytes(
                    registration.keySetDigestHex.decodeHex(32),
                ),
                CanonicalCbor.uint(7) to CanonicalCbor.uint(1),
                CanonicalCbor.uint(8) to CanonicalCbor.bytes(ByteArray(32)),
                CanonicalCbor.uint(9) to CanonicalCbor.bytes(
                    "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
                        .decodeHex(),
                ),
                CanonicalCbor.uint(10) to CanonicalCbor.bytes(
                    "50d8f3689f95e95c30be32dc4e516460dff139c088ab1117af0c104188252949"
                        .decodeHex(),
                ),
                CanonicalCbor.uint(11) to CanonicalCbor.text(endpoint),
                CanonicalCbor.uint(12) to CanonicalCbor.uint(1_799_999_900),
                CanonicalCbor.uint(13) to CanonicalCbor.uint(1_800_086_400),
            ),
        )
        val protectedLength = original[3].toInt() and 0xff
        val protectedHeaders = original.copyOfRange(4, 4 + protectedLength)
        val signature = original.copyOfRange(original.size - 64, original.size)
        return CanonicalCbor.encodeTag(
            tag = 18,
            value = CanonicalCbor.array(
                CanonicalCbor.bytes(protectedHeaders),
                CanonicalCbor.map(),
                CanonicalCbor.bytes(payload),
                CanonicalCbor.bytes(signature),
            ),
        )
    }
}

private fun ByteArray.toHexWithoutPrefix(): String = buildString(size * 2) {
    for (byte in this@toHexWithoutPrefix) {
        val value = byte.toInt() and 0xff
        append("0123456789abcdef"[value ushr 4])
        append("0123456789abcdef"[value and 0x0f])
    }
}

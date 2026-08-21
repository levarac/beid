package org.levarac.parallax.registry

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class SignedDefinitionFetcherTest {
    @Test
    fun matchingCanonicalHashReturnsTypedContextAndPreservesFetchHardening() = runTest {
        val vector = readEventDefinitionVector("vectors/positive/event-definition-v1.json")
        val signed = vector.requiredString("signedEventDefinitionHex").vectorHexBytes()
        val fetcher = SignedDefinitionFetcher(
            template = requireNotNull(createDefinitionUrlTemplate("https://defs.example/{definitionHash}.cose")),
            transport = RecordingRegistryTransport(
                RegistryHttpResponse(statusCode = 200, body = "", bodyBytes = signed),
            ),
        )

        val context = fetcher.fetch(
            eventId = vector.vectorEventId(),
            registration = vector.anchorRegistration(),
            record = vector.definitionRecord(),
            selectedAt = vector.definitionRecord().validFrom,
            encodedEventKeySet = vector.requiredString("eventKeySetHex").vectorHexBytes(),
        )

        assertEquals(vector.requiredString("eventDefinitionDigestHex"), context.definitionHashHex.removePrefix("0x"))
        assertEquals(vector.vectorEventId().toHexWithoutPrefix(), context.eventIdHex.removePrefix("0x"))
        assertEquals("https://operator.example/v1/observations", context.submissionEndpoint)
        assertEquals(1_799_999_900L, context.validFrom.value)
        assertEquals(1_800_086_400L, context.validUntil.value)
        assertEquals(
            "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5",
            context.receiptPublicKey.toByteArray().toHexWithoutPrefix(),
        )
    }

    @Test
    fun hashMismatchIsRejectedBeforeCanonicalDecode() = runTest {
        val vector = readEventDefinitionVector("vectors/positive/event-definition-v1.json")
        val fetcher = SignedDefinitionFetcher(
            template = requireNotNull(createDefinitionUrlTemplate("https://defs.example/{definitionHash}")),
            transport = RecordingRegistryTransport(
                RegistryHttpResponse(statusCode = 200, body = "", bodyBytes = byteArrayOf(1, 2, 3)),
            ),
        )

        val error = assertFailsWith<DefinitionFetchException> {
            fetcher.fetch(
                eventId = vector.vectorEventId(),
                registration = vector.anchorRegistration(),
                record = vector.definitionRecord(),
                selectedAt = vector.definitionRecord().validFrom,
                encodedEventKeySet = vector.requiredString("eventKeySetHex").vectorHexBytes(),
            )
        }
        assertEquals(DefinitionFetchError.HASH_MISMATCH, error.reason)
    }

    @Test
    fun oversizedRemotePayloadIsRejectedBeforeDomainHashing() = runTest {
        val vector = readEventDefinitionVector("vectors/positive/event-definition-v1.json")
        val fetcher = SignedDefinitionFetcher(
            template = requireNotNull(createDefinitionUrlTemplate("https://defs.example/{definitionHash}")),
            transport = RecordingRegistryTransport(
                RegistryHttpResponse(
                    statusCode = 200,
                    body = "",
                    bodyBytes = ByteArray(MAX_EVENT_DEFINITION_PAYLOAD_BYTES + 1),
                ),
            ),
        )

        val error = assertFailsWith<DefinitionFetchException> {
            fetcher.fetch(
                eventId = vector.vectorEventId(),
                registration = vector.anchorRegistration(),
                record = vector.definitionRecord(),
                selectedAt = vector.definitionRecord().validFrom,
                encodedEventKeySet = vector.requiredString("eventKeySetHex").vectorHexBytes(),
            )
        }
        assertEquals(DefinitionFetchError.PAYLOAD_TOO_LARGE, error.reason)
    }

    @Test
    fun malformedBytesWithMatchingDomainHashBecomeTypedFetchDecodeError() = runTest {
        val vector = readEventDefinitionVector("vectors/positive/event-definition-v1.json")
        val payload = byteArrayOf(1, 2, 3)
        val base = vector.definitionRecord()
        val record = RegistryDefinitionRecord(
            sequence = base.sequence,
            previousDefinitionDigestHex = base.previousDefinitionDigestHex,
            definitionDigestHex = EventDefinitionCborCodec.eventDefinitionDigest(payload).toPrefixedHex(),
            validFrom = base.validFrom,
            validUntil = base.validUntil,
            anchoredAt = base.anchoredAt,
        )
        val fetcher = SignedDefinitionFetcher(
            template = requireNotNull(createDefinitionUrlTemplate("https://defs.example/{definitionHash}")),
            transport = RecordingRegistryTransport(
                RegistryHttpResponse(statusCode = 200, body = "", bodyBytes = payload),
            ),
        )

        val error = assertFailsWith<DefinitionFetchException> {
            fetcher.fetch(
                eventId = vector.vectorEventId(),
                registration = vector.anchorRegistration(),
                record = record,
                selectedAt = base.validFrom,
                encodedEventKeySet = vector.requiredString("eventKeySetHex").vectorHexBytes(),
            )
        }
        assertEquals(DefinitionFetchError.DECODE_ERROR, error.reason)
        assertEquals(DefinitionDecodeException::class, error.cause!!::class)
        assertEquals(DefinitionDecodeError.MALFORMED, (error.cause as DefinitionDecodeException).reason)
    }

    @Test
    fun invalidKeySetArtifactBecomesTypedFetchDecodeError() = runTest {
        val vector = readEventDefinitionVector("vectors/positive/event-definition-v1.json")
        val signed = vector.requiredString("signedEventDefinitionHex").vectorHexBytes()
        val fetcher = SignedDefinitionFetcher(
            template = requireNotNull(createDefinitionUrlTemplate("https://defs.example/{definitionHash}")),
            transport = RecordingRegistryTransport(
                RegistryHttpResponse(statusCode = 200, body = "", bodyBytes = signed),
            ),
        )
        val error = assertFailsWith<DefinitionFetchException> {
            fetcher.fetch(
                eventId = vector.vectorEventId(),
                registration = vector.anchorRegistration(),
                record = vector.definitionRecord(),
                selectedAt = vector.definitionRecord().validFrom,
                encodedEventKeySet = byteArrayOf(),
            )
        }
        assertEquals(DefinitionFetchError.DECODE_ERROR, error.reason)
        assertEquals(DefinitionDecodeException::class, error.cause!!::class)
        assertEquals(DefinitionDecodeError.INVALID_KEY_SET, (error.cause as DefinitionDecodeException).reason)
    }
}

private fun ByteArray.toHexWithoutPrefix(): String = buildString(size * 2) {
    for (byte in this@toHexWithoutPrefix) {
        val value = byte.toInt() and 0xff
        append("0123456789abcdef"[value ushr 4])
        append("0123456789abcdef"[value and 0x0f])
    }
}

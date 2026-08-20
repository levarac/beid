package org.levarac.parallax.registry

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class SignedDefinitionFetcherTest {
    @Test
    fun matchingHashReturnsTypedContextAndAppliesForwardWindow() = runTest {
        val payload = eventDefinitionCbor()
        val record = definitionRecordFor(payload)
        val fetcher = SignedDefinitionFetcher(
            template = requireNotNull(createDefinitionUrlTemplate("https://defs.example/{definitionHash}.cbor")),
            transport = RecordingRegistryTransport(
                RegistryHttpResponse(statusCode = 200, body = "", bodyBytes = payload),
            ),
        )

        val context = fetcher.fetch(
            eventId = DEFINITION_EVENT_ID_HEX.fixtureHexToByteArrayForTest(),
            record = record,
            selectedAt = 130L,
        )

        assertEquals(record.definitionDigestHex, context.definitionHashHex)
        assertEquals(0, context.definition.activeDelegationCount(129L))
        assertEquals(1, context.definition.activeDelegationCount(130L))
        assertEquals(1, context.activeDelegationCount)
        assertEquals(0, context.definition.activeDelegationCount(181L))
    }

    @Test
    fun hashMismatchIsRejectedBeforeDecode() = runTest {
        val payload = eventDefinitionCbor()
        val record = definitionRecordFor(payload + 0x00)
        val fetcher = SignedDefinitionFetcher(
            template = requireNotNull(createDefinitionUrlTemplate("https://defs.example/{definitionHash}")),
            transport = RecordingRegistryTransport(
                RegistryHttpResponse(statusCode = 200, body = "", bodyBytes = payload),
            ),
        )

        val error = assertFailsWith<DefinitionFetchException> {
            fetcher.fetch(
                eventId = DEFINITION_EVENT_ID_HEX.fixtureHexToByteArrayForTest(),
                record = record,
                selectedAt = 150L,
            )
        }
        assertEquals(DefinitionFetchError.HASH_MISMATCH, error.reason)
    }

    @Test
    fun malformedBytesWithMatchingHashBecomeTypedFetchDecodeError() = runTest {
        val payload = byteArrayOf(0x01, 0x02, 0x03)
        val fetcher = SignedDefinitionFetcher(
            template = requireNotNull(createDefinitionUrlTemplate("https://defs.example/{definitionHash}")),
            transport = RecordingRegistryTransport(
                RegistryHttpResponse(statusCode = 200, body = "", bodyBytes = payload),
            ),
        )

        val error = assertFailsWith<DefinitionFetchException> {
            fetcher.fetch(
                eventId = DEFINITION_EVENT_ID_HEX.fixtureHexToByteArrayForTest(),
                record = definitionRecordFor(payload),
                selectedAt = 150L,
            )
        }
        assertEquals(DefinitionFetchError.DECODE_ERROR, error.reason)
        assertEquals(DefinitionDecodeException::class, error.cause!!::class)
    }
}

private fun String.fixtureHexToByteArrayForTest(): ByteArray {
    val digits = removePrefix("0x")
    return ByteArray(digits.length / 2) { index ->
        val offset = index * 2
        ((digits[offset].digitToInt(16) shl 4) or digits[offset + 1].digitToInt(16)).toByte()
    }
}

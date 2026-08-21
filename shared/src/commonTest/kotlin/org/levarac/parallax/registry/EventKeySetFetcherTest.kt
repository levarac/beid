package org.levarac.parallax.registry

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class EventKeySetFetcherTest {
    @Test
    fun differentEventKeySetDigestsResolveIndependentlyAndReuseOnlyTheirOwnCacheEntry() = runTest {
        val positive = readEventDefinitionVector("vectors/positive/event-definition-v1.json")
        val negative = readEventDefinitionVector("vectors/negative/event-definition-v1.json")
        val firstKeySet = positive.requiredString("eventKeySetHex").vectorHexBytes()
        val secondKeySet = negative.requiredString("substitutedEventKeySetHex").vectorHexBytes()
        val firstDigest = EventDefinitionCborCodec.eventKeySetDigest(firstKeySet).toPrefixedHex()
        val secondDigest = EventDefinitionCborCodec.eventKeySetDigest(secondKeySet).toPrefixedHex()
        assertEquals(firstDigest, positive.requiredString("keySetDigestHex").let { "0x$it" })
        assertEquals(firstDigest != secondDigest, true)

        val transport = RecordingRegistryTransport(
            RegistryHttpResponse(statusCode = 200, body = "", bodyBytes = firstKeySet),
            RegistryHttpResponse(statusCode = 200, body = "", bodyBytes = secondKeySet),
        )
        val fetcher = EventKeySetFetcher(
            template = requireNotNull(createEventKeySetUrlTemplate("https://keys.example/{keySetDigest}.cbor")),
            transport = transport,
        )

        assertContentEquals(firstKeySet, fetcher.fetch(firstDigest))
        assertContentEquals(secondKeySet, fetcher.fetch(secondDigest))
        assertContentEquals(firstKeySet, fetcher.fetch(firstDigest))

        assertEquals(2, transport.requests.size)
        assertEquals("https://keys.example/${firstDigest.removePrefix("0x")}.cbor", transport.requests[0].url)
        assertEquals("https://keys.example/${secondDigest.removePrefix("0x")}.cbor", transport.requests[1].url)
    }

    @Test
    fun digestMismatchIsRejectedBeforeTheArtifactCanEnterTheCache() = runTest {
        val positive = readEventDefinitionVector("vectors/positive/event-definition-v1.json")
        val expectedKeySet = positive.requiredString("eventKeySetHex").vectorHexBytes()
        val substitutedKeySet = readEventDefinitionVector("vectors/negative/event-definition-v1.json")
            .requiredString("substitutedEventKeySetHex")
            .vectorHexBytes()
        val expectedDigest = EventDefinitionCborCodec.eventKeySetDigest(expectedKeySet).toPrefixedHex()
        val transport = RecordingRegistryTransport(
            RegistryHttpResponse(statusCode = 200, body = "", bodyBytes = substitutedKeySet),
        )
        val fetcher = EventKeySetFetcher(
            template = requireNotNull(createEventKeySetUrlTemplate("https://keys.example/{keySetDigest}")),
            transport = transport,
        )

        val error = assertFailsWith<DefinitionFetchException> {
            fetcher.fetch(expectedDigest)
        }
        assertEquals(DefinitionFetchError.KEY_SET_HASH_MISMATCH, error.reason)
        assertEquals(1, transport.requests.size)
    }

    @Test
    fun unavailableArtifactHasATypedFetchReason() = runTest {
        val digest = "0x" + "11".repeat(32)
        val fetcher = EventKeySetFetcher(
            template = requireNotNull(createEventKeySetUrlTemplate("https://keys.example/{keySetDigest}")),
            transport = RecordingRegistryTransport(
                RegistryHttpResponse(statusCode = 404, body = "not found"),
            ),
        )

        val error = assertFailsWith<DefinitionFetchException> {
            fetcher.fetch(digest)
        }
        assertEquals(DefinitionFetchError.KEY_SET_HTTP_ERROR, error.reason)
    }
}

package org.levarac.parallax.registry

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull

class EventCodeHashLookupFetcherTest {
    @Test fun resolvesExactlyLowercaseHash() = runTest {
        val transport = RecordingRegistryTransport(RegistryHttpResponse(200, "{\"eventId\":\"${"01".repeat(32)}\"}"))
        val fetcher = EventCodeHashLookupFetcher(requireNotNull(createEventCodeHashLookupUrlTemplate("https://operator.example/{hash}")), transport)
        assertEquals("0x" + "01".repeat(32), fetcher.fetch("0011223344556677"))
        assertEquals("https://operator.example/0011223344556677", transport.requests.single().url)
    }

    @Test fun maps404AndMalformedResponses() = runTest {
        val template = requireNotNull(createEventCodeHashLookupUrlTemplate("https://operator.example/{hash}"))
        val missing = assertFailsWith<EventCodeLookupException> {
            EventCodeHashLookupFetcher(template, RecordingRegistryTransport(RegistryHttpResponse(404, "{}"))).fetch("0011223344556677")
        }
        assertEquals(EventCodeLookupError.NOT_FOUND, missing.reason)
        val malformed = assertFailsWith<EventCodeLookupException> {
            EventCodeHashLookupFetcher(template, RecordingRegistryTransport(RegistryHttpResponse(200, "{}"))).fetch("0011223344556677")
        }
        assertEquals(EventCodeLookupError.INVALID_RESPONSE, malformed.reason)
    }
}

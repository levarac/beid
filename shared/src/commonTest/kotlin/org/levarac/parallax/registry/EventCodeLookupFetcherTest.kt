package org.levarac.parallax.registry

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

private class FakeRegistryHttpTransport(
    private val respond: (RegistryHttpRequest) -> RegistryHttpResponse,
) : RegistryHttpTransport {
    var lastRequest: RegistryHttpRequest? = null
        private set

    override suspend fun execute(request: RegistryHttpRequest): RegistryHttpResponse {
        lastRequest = request
        return respond(request)
    }
}

private const val TEMPLATE = "https://operator.example/v1/events/by-code/{code}"
private val VALID_EVENT_ID_HEX = "0x" + "1a".repeat(32)

class EventCodeLookupFetcherTest {
    @Test
    fun fetchReturnsTheEventIdFromASuccessfulLookup() = runTest {
        val transport = FakeRegistryHttpTransport { request ->
            assertEquals("GET", request.method)
            assertEquals("https://operator.example/v1/events/by-code/ethtokyo2026", request.url)
            RegistryHttpResponse(statusCode = 200, body = """{"eventId":"$VALID_EVENT_ID_HEX"}""")
        }
        val fetcher = EventCodeLookupFetcher(requireTemplate(), transport)

        val result = fetcher.fetch("ethtokyo2026")

        assertEquals(VALID_EVENT_ID_HEX, result)
    }

    @Test
    fun fetchPercentEncodesCodesWithInternalWhitespace() = runTest {
        val transport = FakeRegistryHttpTransport { request ->
            assertEquals(
                "https://operator.example/v1/events/by-code/eth%20tokyo",
                request.url,
            )
            RegistryHttpResponse(statusCode = 200, body = """{"eventId":"$VALID_EVENT_ID_HEX"}""")
        }
        val fetcher = EventCodeLookupFetcher(requireTemplate(), transport)

        fetcher.fetch("eth tokyo")
    }

    @Test
    fun fetchThrowsNotFoundOn404() = runTest {
        val transport = FakeRegistryHttpTransport {
            RegistryHttpResponse(statusCode = 404, body = "")
        }
        val fetcher = EventCodeLookupFetcher(requireTemplate(), transport)

        val error = assertFailsWith<EventCodeLookupException> { fetcher.fetch("unknown-code") }

        assertEquals(EventCodeLookupError.NOT_FOUND, error.reason)
    }

    @Test
    fun fetchThrowsHttpErrorOnServerError() = runTest {
        val transport = FakeRegistryHttpTransport {
            RegistryHttpResponse(statusCode = 500, body = "")
        }
        val fetcher = EventCodeLookupFetcher(requireTemplate(), transport)

        val error = assertFailsWith<EventCodeLookupException> { fetcher.fetch("some-code") }

        assertEquals(EventCodeLookupError.HTTP_ERROR, error.reason)
    }

    @Test
    fun fetchThrowsHttpErrorOnTransportTimeout() = runTest {
        val transport = FakeRegistryHttpTransport { throw RegistryTransportTimeoutException() }
        val fetcher = EventCodeLookupFetcher(requireTemplate(), transport)

        val error = assertFailsWith<EventCodeLookupException> { fetcher.fetch("some-code") }

        assertEquals(EventCodeLookupError.HTTP_ERROR, error.reason)
    }

    @Test
    fun fetchThrowsInvalidResponseOnMalformedJson() = runTest {
        val transport = FakeRegistryHttpTransport {
            RegistryHttpResponse(statusCode = 200, body = "not json")
        }
        val fetcher = EventCodeLookupFetcher(requireTemplate(), transport)

        val error = assertFailsWith<EventCodeLookupException> { fetcher.fetch("some-code") }

        assertEquals(EventCodeLookupError.INVALID_RESPONSE, error.reason)
    }

    @Test
    fun fetchThrowsInvalidResponseWhenEventIdKeyIsMissing() = runTest {
        val transport = FakeRegistryHttpTransport {
            RegistryHttpResponse(statusCode = 200, body = "{}")
        }
        val fetcher = EventCodeLookupFetcher(requireTemplate(), transport)

        val error = assertFailsWith<EventCodeLookupException> { fetcher.fetch("some-code") }

        assertEquals(EventCodeLookupError.INVALID_RESPONSE, error.reason)
    }

    @Test
    fun fetchThrowsInvalidResponseWhenEventIdIsNotThirtyTwoBytes() = runTest {
        val transport = FakeRegistryHttpTransport {
            RegistryHttpResponse(statusCode = 200, body = """{"eventId":"0xbad"}""")
        }
        val fetcher = EventCodeLookupFetcher(requireTemplate(), transport)

        val error = assertFailsWith<EventCodeLookupException> { fetcher.fetch("some-code") }

        assertEquals(EventCodeLookupError.INVALID_RESPONSE, error.reason)
    }

    @Test
    fun createEventCodeLookupUrlTemplateRejectsATemplateWithoutThePlaceholder() {
        assertTrue(createEventCodeLookupUrlTemplate("https://operator.example/lookup") == null)
    }

    @Test
    fun createEventCodeLookupUrlTemplateRejectsInsecureHttp() {
        assertTrue(
            createEventCodeLookupUrlTemplate("http://operator.example/{code}") == null,
        )
    }

    private fun requireTemplate(): EventCodeLookupUrlTemplate =
        requireNotNull(createEventCodeLookupUrlTemplate(TEMPLATE))
}

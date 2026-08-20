package org.levarac.parallax.registry

import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import org.junit.Test
import kotlin.test.assertEquals

class LocalDefinitionHttpStubTest {
    @Test
    fun fetchesSignedDefinitionBytesThroughThePlatformHttpTransport() {
        val payload = eventDefinitionCbor()
        val eventId = DEFINITION_EVENT_ID_HEX.decodeHex(expectedBytes = 32)
        val record = definitionRecordFor(payload)
        var requestedPath: String? = null
        val server = HttpServer.create(java.net.InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange ->
            requestedPath = exchange.requestURI.path
            exchange.sendResponseHeaders(200, payload.size.toLong())
            exchange.responseBody.use { output -> output.write(payload) }
        }
        server.start()
        try {
            val template = requireNotNull(
                createDefinitionUrlTemplate(
                    "http://127.0.0.1:${server.address.port}/{definitionHash}.cbor",
                ),
            )
            runBlocking {
                val context = SignedDefinitionFetcher(
                    template = template,
                    transport = createPlatformRegistryHttpTransport(),
                ).fetch(
                    eventId = eventId,
                    record = record,
                    selectedAt = 130L,
                )
                assertEquals(record.definitionDigestHex, context.definitionHashHex)
                assertEquals(DEFINITION_EVENT_ID_HEX, context.eventIdHex.removePrefix("0x"))
                assertEquals(record.validFrom, context.definition.validFrom)
                assertEquals(record.validUntil, context.definition.validUntil)
                assertEquals(1, context.activeDelegationCount)
            }
            assertEquals(
                "/${record.definitionDigestHex.removePrefix("0x")}.cbor",
                requestedPath,
            )
        } finally {
            server.stop(0)
        }
    }
}

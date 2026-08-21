package org.levarac.parallax.registry

import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import org.junit.Test
import kotlin.test.assertEquals

class LocalDefinitionHttpStubTest {
    @Test
    fun fetchesCanonicalSignedDefinitionBytesThroughThePlatformHttpTransport() {
        val vector = readEventDefinitionVector("vectors/positive/event-definition-v1.json")
        val payload = vector.requiredString("signedEventDefinitionHex").vectorHexBytes()
        val eventId = vector.vectorEventId()
        val registration = vector.anchorRegistration()
        val record = vector.definitionRecord()
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
                    "http://127.0.0.1:${server.address.port}/{definitionHash}.cose",
                    allowInsecureLoopbackForTests = true,
                ),
            )
            runBlocking {
                val context = SignedDefinitionFetcher(
                    template = template,
                    transport = createPlatformRegistryHttpTransport(),
                    encodedEventKeySet = vector.requiredString("eventKeySetHex").vectorHexBytes(),
                ).fetch(
                    eventId = eventId,
                    registration = registration,
                    record = record,
                    selectedAt = record.validFrom,
                )
                assertEquals(record.definitionDigestHex, context.definitionHashHex)
                assertEquals(eventId.toPrefixedHex(), context.eventIdHex)
                assertEquals(record.validFrom, context.validFrom.value)
                assertEquals(record.validUntil, context.validUntil.value)
                assertEquals("https://operator.example/v1/observations", context.submissionEndpoint)
            }
            assertEquals(
                "/${record.definitionDigestHex.removePrefix("0x")}.cose",
                requestedPath,
            )
        } finally {
            server.stop(0)
        }
    }
}

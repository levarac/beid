package org.levarac.parallax.registry

import kotlinx.coroutines.runBlocking
import org.junit.Assume
import org.junit.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class LocalAnvilEventRegistryIntegrationTest {
    @Test
    fun readsTheRealReaderFacadeAtAPinnedBlockAndCachesTheResult() {
        Assume.assumeTrue(
            "Set BEID_RUN_ANVIL_REGISTRY_TEST=1 and provide the Anvil fixture variables",
            System.getenv("BEID_RUN_ANVIL_REGISTRY_TEST") == "1",
        )

        val rpcUrl = requiredEnvironment("BEID_ANVIL_RPC_URL")
        val readerAddress = requiredEnvironment("BEID_EVENT_REGISTRY_READER_ADDRESS")
        val eventId = requiredEnvironment("BEID_EVENT_ID_HEX").decodeHex(expectedBytes = 32)
        val expectedCbor = requiredEnvironment("BEID_EXPECTED_CBOR_HEX").decodeHex()

        runBlocking {
            val transport = CountingTransport(createPlatformRegistryHttpTransport())
            val primary = JsonRpcEthCallAdapter(rpcUrl, readerAddress, transport)
            val secondary = JsonRpcEthCallAdapter(rpcUrl, readerAddress, transport)
            val cache = InMemoryRegistryCache()
            val resolver = RegistryResolver(
                chainId = 31_337,
                readerAddressHex = readerAddress,
                primary = primary,
                secondary = secondary,
                etherscan = null,
                cache = cache,
                retryDelay = NoRetryDelay,
                jitter = JitterSource { 0 },
                maxAttempts = 1,
            )

            val first = resolver.resolve(eventId, safeRegistryReadPin())
            assertContentEquals(expectedCbor, first.rawCbor)
            assertEquals(1, first.context.schemaVersion)
            assertEquals(1, first.context.definitionState)
            assertEquals(1, first.context.definitionCount)
            assertEquals(first.context.latestDefinitionDigestHex, first.cacheKey.definitionHashHex)
            assertEquals(31_337, first.cacheKey.chainId)
            val requestsAfterFirstRead = transport.requestCount

            val second = resolver.resolve(
                eventId,
                requireNotNull(strictRegistryReadPin(first.cacheKey.blockHashHex)),
            )
            assertContentEquals(first.rawCbor, second.rawCbor)
            assertEquals(requestsAfterFirstRead, transport.requestCount, "strict cache hit must perform no HTTP")

            val refreshedSafe = resolver.resolve(eventId, safeRegistryReadPin())
            assertContentEquals(first.rawCbor, refreshedSafe.rawCbor)
            assertEquals(
                requestsAfterFirstRead + 1,
                transport.requestCount,
                "moving safe pin must refresh its block header before reusing pinned CBOR",
            )
        }
    }

    private fun requiredEnvironment(name: String): String =
        System.getenv(name)?.takeIf { it.isNotBlank() }
            ?: error("$name is required when BEID_RUN_ANVIL_REGISTRY_TEST=1")

    private class CountingTransport(private val delegate: RegistryHttpTransport) : RegistryHttpTransport {
        var requestCount: Int = 0
            private set

        override suspend fun execute(request: RegistryHttpRequest): RegistryHttpResponse {
            requestCount += 1
            return delegate.execute(request)
        }
    }

    private object NoRetryDelay : RetryDelay {
        override suspend fun wait(delayMillis: Long) = Unit
    }
}

package org.levarac.parallax.registry

import kotlinx.coroutines.runBlocking
import org.junit.Assume
import org.junit.Test
import kotlin.test.assertEquals

class SepoliaEventRegistryIntegrationTest {
    @Test
    fun readsDemoEventFromLiveReaderAtSafeBlock() {
        Assume.assumeTrue(
            "Set BEID_RUN_SEPOLIA_REGISTRY_TEST=1 to run the live Sepolia check",
            System.getenv("BEID_RUN_SEPOLIA_REGISTRY_TEST") == "1",
        )

        val readerAddress = "0xd4852f8526A1555A1b2C34145f0eCDA412a53c51"
        val transport = createPlatformRegistryHttpTransport()
        val resolver = RegistryResolver(
            chainId = 11_155_111,
            readerAddressHex = readerAddress,
            primary = JsonRpcEthCallAdapter(
                endpointUrl = "https://ethereum-sepolia-rpc.publicnode.com",
                readerAddressHex = readerAddress,
                transport = transport,
            ),
            secondary = JsonRpcEthCallAdapter(
                endpointUrl = "https://public.1rpc.io/sepolia",
                readerAddressHex = readerAddress,
                transport = transport,
            ),
            etherscan = null,
            cache = InMemoryRegistryCache(),
        )

        runBlocking {
            val resolved = resolver.resolve(
                eventId = "0x0e36d348403d024a8d1b180d1fe69db697d27960e572e1a05f4a42f3f61dcd6f"
                    .decodeHex(expectedBytes = 32),
                pin = safeRegistryReadPin(),
            )
            assertEquals(183, resolved.rawCbor.size)
            assertEquals(1, resolved.context.schemaVersion)
        }
    }
}

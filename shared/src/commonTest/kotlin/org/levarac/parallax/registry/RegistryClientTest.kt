package org.levarac.parallax.registry

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class RegistryClientTest {
    @Test
    fun invalidDefinitionTemplateSurfacesTypedConfigurationError() = runTest {
        val client = requireNotNull(
            createSepoliaRegistryClient(
                readerAddressHex = RegistryTestFixtures.READER,
                etherscanApiKey = null,
                definitionUrlTemplate = "http://defs.example/{definitionHash}",
            ),
        )
        val resolution = CompletableDeferred<EventDefinitionResolution>()
        try {
            client.resolveEventDefinition(
                eventIdHex = "0x" + "01".repeat(32),
                pin = safeRegistryReadPin(),
                useTimeEpochSeconds = 150L,
            ) { resolution.complete(it) }

            val result = resolution.await()
            assertFalse(result.isSuccess)
            assertEquals("definition_invalid_url_template", result.errorCode)
        } finally {
            client.close()
        }
    }
}

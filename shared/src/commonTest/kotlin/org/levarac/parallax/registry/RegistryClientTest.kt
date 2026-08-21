package org.levarac.parallax.registry

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class RegistryClientTest {
    @Test
    fun invalidDefinitionTemplateSurfacesTypedConfigurationError() = runTest {
        assertInvalidDefinitionTemplate("http://defs.example/{definitionHash}")
    }

    @Test
    fun localhostHttpDefinitionTemplateSurfacesTypedConfigurationError() = runTest {
        assertInvalidDefinitionTemplate("http://localhost:8545/{definitionHash}")
    }

    @Test
    fun loopbackAddressHttpDefinitionTemplateSurfacesTypedConfigurationError() = runTest {
        assertInvalidDefinitionTemplate("http://127.0.0.1:8545/{definitionHash}")
    }

    private suspend fun assertInvalidDefinitionTemplate(template: String) {
        val client = requireNotNull(
            createSepoliaRegistryClient(
                readerAddressHex = RegistryTestFixtures.READER,
                etherscanApiKey = null,
                definitionUrlTemplate = template,
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

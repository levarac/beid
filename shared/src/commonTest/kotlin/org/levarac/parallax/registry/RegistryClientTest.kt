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

    @Test
    fun missingEventKeySetUrlTemplateSurfacesATypedConfigurationError() = runTest {
        val client = requireNotNull(
            createSepoliaRegistryClient(
                readerAddressHex = RegistryTestFixtures.READER,
                etherscanApiKey = null,
                definitionUrlTemplate = "https://defs.example/{definitionHash}",
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
            assertEquals("definition_key_set_not_configured", result.errorCode)
        } finally {
            client.close()
        }
    }

    @Test
    fun invalidEventKeySetUrlTemplateSurfacesATypedConfigurationError() = runTest {
        val client = requireNotNull(
            createSepoliaRegistryClient(
                readerAddressHex = RegistryTestFixtures.READER,
                etherscanApiKey = null,
                definitionUrlTemplate = "https://defs.example/{definitionHash}",
                eventKeySetUrlTemplate = "http://keys.example/{keySetDigest}",
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
            assertEquals("definition_key_set_invalid_url_template", result.errorCode)
        } finally {
            client.close()
        }
    }

    @Test
    fun resolveEventIdWithNoUrlTemplateConfiguredSurfacesATypedConfigurationError() = runTest {
        val client = requireNotNull(
            createSepoliaRegistryClient(
                readerAddressHex = RegistryTestFixtures.READER,
                etherscanApiKey = null,
            ),
        )
        val resolution = CompletableDeferred<EventIdLookupResolution>()
        try {
            client.resolveEventId(code = "ethtokyo2026") { resolution.complete(it) }

            val result = resolution.await()
            assertFalse(result.isSuccess)
            assertEquals("event_code_lookup_not_configured", result.errorCode)
        } finally {
            client.close()
        }
    }

    @Test
    fun resolveEventIdWithAnInvalidUrlTemplateSurfacesATypedConfigurationError() = runTest {
        val client = requireNotNull(
            createSepoliaRegistryClient(
                readerAddressHex = RegistryTestFixtures.READER,
                etherscanApiKey = null,
                eventCodeLookupUrlTemplate = "http://lookup.example/{code}",
            ),
        )
        val resolution = CompletableDeferred<EventIdLookupResolution>()
        try {
            client.resolveEventId(code = "ethtokyo2026") { resolution.complete(it) }

            val result = resolution.await()
            assertFalse(result.isSuccess)
            assertEquals("event_code_lookup_invalid_url_template", result.errorCode)
        } finally {
            client.close()
        }
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

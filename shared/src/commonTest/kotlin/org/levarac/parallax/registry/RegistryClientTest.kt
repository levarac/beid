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

    @Test
    fun resolveEventDefinitionWithNoRegistryDefinitionsSurfacesNotFound() = runTest {
        val result = resolveWithFixtureContext(
            cbor = codecRegistryContextFixture(records = emptyList()),
            useTimeEpochSeconds = 105L,
        )

        assertFalse(result.isSuccess)
        assertEquals("definition_not_found", result.errorCode)
    }

    @Test
    fun resolveEventDefinitionWithAValidityGapStillSurfacesValidityMismatch() = runTest {
        val result = resolveWithFixtureContext(
            cbor = codecRegistryContextFixture(
                records = listOf(
                    CodecDefinitionFixture(
                        sequence = 1L,
                        previousDefinitionDigestHex = CODEC_ZERO_DIGEST_HEX,
                        definitionDigestHex = "00".repeat(31) + "a1",
                        validFrom = 100L,
                        validUntil = 110L,
                        anchoredAt = 90L,
                    ),
                ),
                registeredAt = 50L,
            ),
            // after validUntil=110: a gap in an event that DOES have definitions,
            // must stay VALIDITY_MISMATCH, not collapse into NOT_FOUND.
            useTimeEpochSeconds = 200L,
        )

        assertFalse(result.isSuccess)
        assertEquals("definition_validity_mismatch", result.errorCode)
    }

    private suspend fun resolveWithFixtureContext(
        cbor: ByteArray,
        useTimeEpochSeconds: Long,
    ): EventDefinitionResolution {
        val primaryTransport = RecordingRegistryTransport(
            RegistryTestFixtures.headerResponse(),
            RegistryTestFixtures.callResponse(cbor),
        )
        val secondaryTransport = RecordingRegistryTransport(RegistryTestFixtures.callResponse(cbor))
        val resolver = RegistryResolver(
            chainId = 11_155_111L,
            readerAddressHex = RegistryTestFixtures.READER,
            primary = JsonRpcEthCallAdapter(
                RegistryTestFixtures.ENDPOINT,
                RegistryTestFixtures.READER,
                primaryTransport,
            ),
            secondary = JsonRpcEthCallAdapter(
                RegistryTestFixtures.SECONDARY_ENDPOINT,
                RegistryTestFixtures.READER,
                secondaryTransport,
            ),
            etherscan = null,
            cache = InMemoryRegistryCache(),
        )
        val neverCalledTransport = RecordingRegistryTransport(emptyList())
        val client = RegistryClient(
            resolver = resolver,
            definitionFetcher = SignedDefinitionFetcher(
                requireNotNull(createDefinitionUrlTemplate("https://defs.example/{definitionHash}")),
                neverCalledTransport,
            ),
            eventKeySetFetcher = EventKeySetFetcher(
                requireNotNull(createEventKeySetUrlTemplate("https://keys.example/{keySetDigest}")),
                neverCalledTransport,
            ),
        )
        val resolution = CompletableDeferred<EventDefinitionResolution>()
        try {
            client.resolveEventDefinition(
                eventIdHex = RegistryTestFixtures.eventId.toPrefixedHex(),
                pin = safeRegistryReadPin(),
                useTimeEpochSeconds = useTimeEpochSeconds,
            ) { resolution.complete(it) }
            return resolution.await()
        } finally {
            client.close()
        }
    }
}

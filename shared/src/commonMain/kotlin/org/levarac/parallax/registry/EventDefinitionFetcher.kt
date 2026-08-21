package org.levarac.parallax.registry

/**
 * Validated URL template for signed definitions.
 *
 * The only substitution is the lowercase, unprefixed 64-character SHA-256
 * definition hash. Production templates must be HTTPS; loopback HTTP is
 * accepted solely for the opt-in local integration fixture.
 */
public class DefinitionUrlTemplate internal constructor(
    private val template: String,
) {
    internal fun urlFor(definitionHashHex: String): String {
        val hash = definitionHashHex.removePrefix("0x")
        return template.replace(DEFINITION_HASH_PLACEHOLDER, hash)
    }
}

public fun createDefinitionUrlTemplate(
    template: String,
    allowInsecureLoopbackForTests: Boolean = false,
): DefinitionUrlTemplate? = try {
    val normalized = template.trim()
    require(normalized.count { it == '{' } == 1 && normalized.count { it == '}' } == 1) {
        "definition URL template must contain exactly one placeholder"
    }
    require(normalized.contains(DEFINITION_HASH_PLACEHOLDER)) {
        "definition URL template must contain {definitionHash}"
    }
    val probe = normalized.replace(DEFINITION_HASH_PLACEHOLDER, "0".repeat(64))
    validateEndpointUrl(probe, allowInsecureLoopbackForTests)
    DefinitionUrlTemplate(normalized)
} catch (_: IllegalArgumentException) {
    null
}

internal class SignedDefinitionFetcher(
    private val template: DefinitionUrlTemplate,
    private val transport: RegistryHttpTransport,
) {
    internal suspend fun fetch(
        eventId: ByteArray,
        record: RegistryDefinitionRecord,
        selectedAt: Long,
    ): EventDefinitionContext {
        val expectedHash = record.definitionDigestHex
        val response = try {
            transport.execute(
                RegistryHttpRequest(
                    method = "GET",
                    url = template.urlFor(expectedHash),
                    headers = mapOf("Accept" to "application/cbor"),
                ),
            )
        } catch (error: RegistryTransportTimeoutException) {
            throw DefinitionFetchException(
                DefinitionFetchError.HTTP_ERROR,
                "signed definition request timed out",
                error,
            )
        } catch (error: kotlinx.coroutines.CancellationException) {
            throw error
        } catch (error: Throwable) {
            throw DefinitionFetchException(
                DefinitionFetchError.HTTP_ERROR,
                "signed definition request failed",
                error,
            )
        }
        if (response.statusCode !in 200..299) {
            throw DefinitionFetchException(
                DefinitionFetchError.HTTP_ERROR,
                "signed definition returned HTTP ${response.statusCode}",
            )
        }
        val bytes = response.bodyBytes
        if (bytes.size > MAX_EVENT_DEFINITION_PAYLOAD_BYTES) {
            throw DefinitionFetchException(
                DefinitionFetchError.PAYLOAD_TOO_LARGE,
                "signed definition response exceeds the configured limit",
            )
        }
        val actualHash = Sha256.digest(bytes).toPrefixedHex()
        if (actualHash != expectedHash) {
            throw DefinitionFetchException(
                DefinitionFetchError.HASH_MISMATCH,
                "signed definition hash does not match the chain record",
            )
        }
        val definition = try {
            EventDefinitionCborCodec.decode(bytes)
        } catch (error: DefinitionDecodeException) {
            throw DefinitionFetchException(
                DefinitionFetchError.DECODE_ERROR,
                "signed definition CBOR is invalid: ${error.reason}",
                error,
            )
        }
        val expectedEventId = eventId.toPrefixedHex()
        if (definition.eventIdHex != expectedEventId) {
            throw DefinitionFetchException(
                DefinitionFetchError.EVENT_ID_MISMATCH,
                "signed definition event ID does not match the registry read",
            )
        }
        if (definition.validFrom != record.validFrom || definition.validUntil != record.validUntil) {
            throw DefinitionFetchException(
                DefinitionFetchError.VALIDITY_MISMATCH,
                "signed definition validity does not match the chain record",
            )
        }
        return EventDefinitionContext(
            eventIdHex = expectedEventId,
            definitionHashHex = expectedHash,
            selectedAt = selectedAt,
            record = record,
            definition = definition,
        )
    }
}

private const val DEFINITION_HASH_PLACEHOLDER: String = "{definitionHash}"

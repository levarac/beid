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
    encodedEventKeySet: ByteArray? = null,
) {
    private val encodedEventKeySet: ByteArray? = encodedEventKeySet?.copyOf()

    internal suspend fun fetch(
        eventId: ByteArray,
        registration: RegistryRegistration,
        record: RegistryDefinitionRecord,
        selectedAt: Long,
    ): EventDefinitionContext {
        val expectedHash = record.definitionDigestHex
        val response = try {
            transport.execute(
                RegistryHttpRequest(
                    method = "GET",
                    url = template.urlFor(expectedHash),
                    headers = mapOf("Accept" to "application/vnd.levarac.event-definition+cose"),
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
        // The chain commitment is the canonical domain-separated Event Definition digest. Keep
        // this before decoding so an untrusted response can never influence parser work first.
        val actualHash = EventDefinitionCborCodec.eventDefinitionDigest(bytes).toPrefixedHex()
        if (actualHash != expectedHash) {
            throw DefinitionFetchException(
                DefinitionFetchError.HASH_MISMATCH,
                "signed definition hash does not match the chain record",
            )
        }
        val keySet = encodedEventKeySet ?: throw DefinitionFetchException(
            DefinitionFetchError.KEY_SET_NOT_CONFIGURED,
            "EventKeySet artifact is required to verify the authority signature",
        )
        val verified = try {
            EventDefinitionCborCodec.verify(
                signedBytes = bytes,
                encodedKeySet = keySet,
                eventId = eventId,
                registration = registration,
                record = record,
                at = selectedAt,
            )
        } catch (error: DefinitionDecodeException) {
            throw DefinitionFetchException(
                DefinitionFetchError.DECODE_ERROR,
                "signed Event Definition is invalid: ${error.reason}",
                error,
            )
        }
        val expectedEventId = eventId.toPrefixedHex()
        return EventDefinitionContext(
            eventIdHex = expectedEventId,
            definitionHashHex = expectedHash,
            selectedAt = selectedAt,
            record = record,
            definition = verified.definition,
        )
    }
}

private const val DEFINITION_HASH_PLACEHOLDER: String = "{definitionHash}"

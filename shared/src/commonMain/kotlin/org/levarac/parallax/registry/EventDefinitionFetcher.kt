package org.levarac.parallax.registry

import kotlinx.coroutines.sync.withLock

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

public class EventKeySetUrlTemplate internal constructor(
    private val template: String,
) {
    internal fun urlFor(keySetDigestHex: String): String {
        val digest = keySetDigestHex.removePrefix("0x")
        return template.replace(EVENT_KEY_SET_DIGEST_PLACEHOLDER, digest)
    }
}

public fun createDefinitionUrlTemplate(
    template: String,
    allowInsecureLoopbackForTests: Boolean = false,
): DefinitionUrlTemplate? = createUrlTemplate(
    template = template,
    placeholder = DEFINITION_HASH_PLACEHOLDER,
    description = "definition",
    allowInsecureLoopbackForTests = allowInsecureLoopbackForTests,
) { DefinitionUrlTemplate(it) }

public fun createEventKeySetUrlTemplate(
    template: String,
    allowInsecureLoopbackForTests: Boolean = false,
): EventKeySetUrlTemplate? = createUrlTemplate(
    template = template,
    placeholder = EVENT_KEY_SET_DIGEST_PLACEHOLDER,
    description = "EventKeySet",
    allowInsecureLoopbackForTests = allowInsecureLoopbackForTests,
) { EventKeySetUrlTemplate(it) }

private fun <T> createUrlTemplate(
    template: String,
    placeholder: String,
    description: String,
    allowInsecureLoopbackForTests: Boolean,
    factory: (String) -> T,
): T? = try {
    val normalized = template.trim()
    require(normalized.count { it == '{' } == 1 && normalized.count { it == '}' } == 1) {
        "$description URL template must contain exactly one placeholder"
    }
    require(normalized.contains(placeholder)) {
        "$description URL template must contain $placeholder"
    }
    val probe = normalized.replace(placeholder, "0".repeat(64))
    validateEndpointUrl(probe, allowInsecureLoopbackForTests)
    factory(normalized)
} catch (_: IllegalArgumentException) {
    null
}

internal class EventKeySetFetcher(
    private val template: EventKeySetUrlTemplate,
    private val transport: RegistryHttpTransport,
    private val cache: InMemoryEventKeySetCache = InMemoryEventKeySetCache(),
) {
    internal suspend fun fetch(keySetDigestHex: String): ByteArray {
        val expectedDigest = try {
            keySetDigestHex.decodeHex(expectedBytes = EVENT_KEY_SET_DIGEST_BYTES).toPrefixedHex()
        } catch (error: IllegalArgumentException) {
            throw DefinitionFetchException(
                DefinitionFetchError.INVALID_KEY_SET,
                "registry keySetDigest is invalid",
                error,
            )
        }
        cache.find(expectedDigest)?.let { return it }

        val response = try {
            transport.execute(
                RegistryHttpRequest(
                    method = "GET",
                    url = template.urlFor(expectedDigest),
                    headers = mapOf("Accept" to EVENT_KEY_SET_MEDIA_TYPE),
                ),
            )
        } catch (error: RegistryTransportTimeoutException) {
            throw DefinitionFetchException(
                DefinitionFetchError.KEY_SET_HTTP_ERROR,
                "EventKeySet artifact request timed out",
                error,
            )
        } catch (error: kotlinx.coroutines.CancellationException) {
            throw error
        } catch (error: Throwable) {
            throw DefinitionFetchException(
                DefinitionFetchError.KEY_SET_HTTP_ERROR,
                "EventKeySet artifact request failed",
                error,
            )
        }
        if (response.statusCode !in 200..299) {
            throw DefinitionFetchException(
                DefinitionFetchError.KEY_SET_HTTP_ERROR,
                "EventKeySet artifact returned HTTP ${response.statusCode}",
            )
        }
        val bytes = response.bodyBytes
        if (bytes.size > MAX_EVENT_KEY_SET_PAYLOAD_BYTES) {
            throw DefinitionFetchException(
                DefinitionFetchError.KEY_SET_PAYLOAD_TOO_LARGE,
                "EventKeySet artifact exceeds the configured limit",
            )
        }
        val actualDigest = try {
            EventDefinitionCborCodec.eventKeySetDigest(bytes).toPrefixedHex()
        } catch (error: DefinitionDecodeException) {
            throw DefinitionFetchException(
                DefinitionFetchError.INVALID_KEY_SET,
                "EventKeySet artifact is invalid",
                error,
            )
        }
        if (actualDigest != expectedDigest) {
            throw DefinitionFetchException(
                DefinitionFetchError.KEY_SET_HASH_MISMATCH,
                "EventKeySet artifact digest does not match the registry registration",
            )
        }
        cache.put(expectedDigest, bytes)
        return bytes.copyOf()
    }
}

internal class InMemoryEventKeySetCache(
    private val maxEntries: Int = DEFAULT_EVENT_KEY_SET_CACHE_ENTRIES,
) {
    private val mutex = kotlinx.coroutines.sync.Mutex()
    private val values = mutableListOf<CacheEntry>()

    init {
        require(maxEntries > 0) { "maxEntries must be positive" }
    }

    internal suspend fun find(digestHex: String): ByteArray? = mutex.withLock {
        val index = values.indexOfFirst { it.digestHex == digestHex }
        if (index < 0) return@withLock null
        val entry = values.removeAt(index)
        values += entry
        entry.bytes.copyOf()
    }

    internal suspend fun put(digestHex: String, bytes: ByteArray) {
        mutex.withLock {
            values.removeAll { it.digestHex == digestHex }
            values += CacheEntry(digestHex, bytes.copyOf())
            while (values.size > maxEntries) values.removeAt(0)
        }
    }

    private data class CacheEntry(
        val digestHex: String,
        val bytes: ByteArray,
    )

    private companion object {
        const val DEFAULT_EVENT_KEY_SET_CACHE_ENTRIES: Int = 32
    }
}

internal class SignedDefinitionFetcher(
    private val template: DefinitionUrlTemplate,
    private val transport: RegistryHttpTransport,
) {
    internal suspend fun fetch(
        eventId: ByteArray,
        registration: RegistryRegistration,
        record: RegistryDefinitionRecord,
        selectedAt: Long,
        encodedEventKeySet: ByteArray,
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
        val verified = try {
            EventDefinitionCborCodec.verify(
                signedBytes = bytes,
                encodedKeySet = encodedEventKeySet,
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
private const val EVENT_KEY_SET_DIGEST_PLACEHOLDER: String = "{keySetDigest}"
private const val EVENT_KEY_SET_DIGEST_BYTES: Int = 32
private const val EVENT_KEY_SET_MEDIA_TYPE: String =
    "application/vnd.levarac.event-key-set+cbor"
internal const val MAX_EVENT_KEY_SET_PAYLOAD_BYTES: Int = 64 * 1_024

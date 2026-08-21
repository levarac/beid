package org.levarac.parallax.submission

import org.levarac.parallax.observation.ByteString32
import org.levarac.parallax.observation.CompressedSecp256k1PublicKey
import org.levarac.parallax.observation.ImmutableBytes
import org.levarac.parallax.observation.ProtocolUInt
import org.levarac.parallax.observation.Sha256Digest
import org.levarac.parallax.observation.SignedObservationV1
import org.levarac.parallax.registry.EventDefinitionContext

/** Exact bytes and digest retained after the native app has signed an Observation. */
public class StoredObservationV1 internal constructor(
    public val signedBytes: ImmutableBytes,
    public val observationDigest: Sha256Digest,
)

/** The trusted operator endpoint and receipt key selected from an Event Definition. */
public class SubmissionOperatorConfiguration internal constructor(
    public val submissionEndpoint: String,
    public val receiptPublicKey: CompressedSecp256k1PublicKey,
    public val operatorId: ByteString32,
    public val eventId: ByteString32?,
    public val eventDefinitionDigest: ByteString32?,
    public val validFrom: Long?,
    public val validUntil: Long?,
)

public class AcceptanceReceipt internal constructor(
    public val signedBytes: ImmutableBytes,
    public val operatorId: ByteString32,
    public val observationDigest: Sha256Digest,
    public val context: ByteString32,
    public val acceptedAt: ProtocolUInt,
    public val mergeBy: ProtocolUInt,
    public val policyDigest: ByteString32,
)

public enum class SubmissionErrorCode(public val wireName: String) {
    INVALID_CONFIGURATION("invalid_configuration"),
    TIMEOUT("timeout"),
    RATE_LIMITED("rate_limited"),
    SERVER_ERROR("server_error"),
    HTTP_ERROR("http_error"),
    PROTOCOL_ERROR("protocol_error"),
    CONFLICT("conflict"),
    RECEIPT_NOT_FOUND("receipt_not_found"),
    REJECTED("rejected"),
    CANCELLED("cancelled"),
}

public class SubmissionResult internal constructor(
    public val isSuccess: Boolean,
    public val receipt: AcceptanceReceipt?,
    public val statusCode: Int,
    public val isRetryable: Boolean,
    public val errorCode: String?,
    public val errorMessage: String?,
)

public class SubmissionRequest internal constructor(private val cancelJob: () -> Unit) {
    public fun cancel() {
        cancelJob()
    }
}

public fun storeSignedObservation(signed: SignedObservationV1): StoredObservationV1 {
    val exactBytes = signed.cose.toByteArray()
    return StoredObservationV1(
        signedBytes = ImmutableBytes(exactBytes),
        observationDigest = Sha256Digest(observationDigestBytes(exactBytes)),
    )
}

/** Restores exact signed COSE bytes after a native atomic-store reload. */
public fun restoreStoredObservation(signedBytesHex: String): StoredObservationV1? = try {
    val exactBytes = signedBytesHex.decodeHexVariable()
    StoredObservationV1(
        signedBytes = ImmutableBytes(exactBytes),
        observationDigest = Sha256Digest(observationDigestBytes(exactBytes)),
    )
} catch (_: IllegalArgumentException) {
    null
}

public fun createSubmissionOperatorConfiguration(
    endpoint: String,
    receiptPublicKeyHex: String,
    eventIdHex: String? = null,
    eventDefinitionDigestHex: String? = null,
    validFrom: Long? = null,
    validUntil: Long? = null,
    allowInsecureLoopbackForTests: Boolean = false,
): SubmissionOperatorConfiguration? = createSubmissionOperatorConfigurationInternal(
    endpoint = endpoint,
    receiptPublicKeyHex = receiptPublicKeyHex,
    operatorIdHex = null,
    eventIdHex = eventIdHex,
    eventDefinitionDigestHex = eventDefinitionDigestHex,
    validFrom = validFrom,
    validUntil = validUntil,
    allowInsecureLoopbackForTests = allowInsecureLoopbackForTests,
)

/** Restores a durable submission configuration with the operator ID from its verified context. */
public fun createSubmissionOperatorConfigurationWithOperatorId(
    endpoint: String,
    receiptPublicKeyHex: String,
    operatorIdHex: String?,
    eventIdHex: String? = null,
    eventDefinitionDigestHex: String? = null,
    validFrom: Long? = null,
    validUntil: Long? = null,
    allowInsecureLoopbackForTests: Boolean = false,
): SubmissionOperatorConfiguration? = createSubmissionOperatorConfigurationInternal(
    endpoint = endpoint,
    receiptPublicKeyHex = receiptPublicKeyHex,
    operatorIdHex = operatorIdHex,
    eventIdHex = eventIdHex,
    eventDefinitionDigestHex = eventDefinitionDigestHex,
    validFrom = validFrom,
    validUntil = validUntil,
    allowInsecureLoopbackForTests = allowInsecureLoopbackForTests,
)

private fun createSubmissionOperatorConfigurationInternal(
    endpoint: String,
    receiptPublicKeyHex: String,
    operatorIdHex: String?,
    eventIdHex: String?,
    eventDefinitionDigestHex: String?,
    validFrom: Long?,
    validUntil: Long?,
    allowInsecureLoopbackForTests: Boolean,
): SubmissionOperatorConfiguration? = try {
    val normalizedEndpoint = validateSubmissionEndpoint(endpoint, allowInsecureLoopbackForTests)
    val receiptPublicKey = CompressedSecp256k1PublicKey(receiptPublicKeyHex.decodeHex(33))
    val operatorId = operatorIdHex?.let { ByteString32(it.decodeHex(32)) }
        ?: ByteString32(acceptanceOperatorId(receiptPublicKey.toByteArray()))
    val eventId = eventIdHex?.let { ByteString32(it.decodeHex(32)) }
    val definitionDigest = eventDefinitionDigestHex?.let { ByteString32(it.decodeHex(32)) }
    require((validFrom == null) == (validUntil == null)) {
        "Event Definition validity must provide both validFrom and validUntil"
    }
    require(validFrom == null || validFrom <= validUntil!!) {
        "Event Definition validity is inverted"
    }
    buildSubmissionOperatorConfiguration(
        submissionEndpoint = normalizedEndpoint,
        receiptPublicKey = receiptPublicKey,
        operatorId = operatorId,
        eventId = eventId,
        eventDefinitionDigest = definitionDigest,
        validFrom = validFrom,
        validUntil = validUntil,
    )
} catch (_: IllegalArgumentException) {
    null
}

/**
 * Binds submission trust to the registry module's verified Event Definition.
 *
 * Production callers should use this overload. The lower-level overload above
 * remains available for isolated transport tests, but it is not a source of
 * runtime configuration: endpoint, receipt key, event ID, digest, and validity
 * all come from the same fetched definition context here.
 */
public fun createSubmissionOperatorConfiguration(
    context: EventDefinitionContext,
    allowInsecureLoopbackForTests: Boolean = false,
): SubmissionOperatorConfiguration? = try {
    buildSubmissionOperatorConfiguration(
        submissionEndpoint = validateSubmissionEndpoint(
            context.submissionEndpoint,
            allowInsecureLoopbackForTests,
        ),
        receiptPublicKey = context.receiptPublicKey,
        operatorId = context.operatorId,
        eventId = context.eventId,
        eventDefinitionDigest = ByteString32(context.definitionHashHex.decodeHex(32)),
        validFrom = context.validFrom.value,
        validUntil = context.validUntil.value,
    )
} catch (_: IllegalArgumentException) {
    null
}

/** Swift-export-friendly name for the verified-context overload. */
public fun createSubmissionOperatorConfigurationFromEventDefinition(
    context: EventDefinitionContext,
    allowInsecureLoopbackForTests: Boolean = false,
): SubmissionOperatorConfiguration? = createSubmissionOperatorConfiguration(
    context = context,
    allowInsecureLoopbackForTests = allowInsecureLoopbackForTests,
)

internal fun observationDigestBytes(signedBytes: ByteArray): ByteArray =
    sha256DomainDigest("levarac:observation-digest:v1", signedBytes)

internal fun acceptanceOperatorId(publicKey: ByteArray): ByteArray =
    sha256DomainDigest("levarac:operator-id:v1", publicKey)

internal fun acceptanceReceiptDigest(signedBytes: ByteArray): ByteArray =
    sha256DomainDigest("levarac:acceptance-digest:v1", signedBytes)

private fun sha256DomainDigest(domain: String, bytes: ByteArray): ByteArray =
    org.levarac.parallax.observation.Sha256.digest(
        domain.encodeToByteArray() + byteArrayOf(0) + bytes,
    )

private fun buildSubmissionOperatorConfiguration(
    submissionEndpoint: String,
    receiptPublicKey: CompressedSecp256k1PublicKey,
    operatorId: ByteString32,
    eventId: ByteString32?,
    eventDefinitionDigest: ByteString32?,
    validFrom: Long?,
    validUntil: Long?,
): SubmissionOperatorConfiguration {
    require(operatorId.toByteArray().contentEquals(acceptanceOperatorId(receiptPublicKey.toByteArray()))) {
        "Event Definition operatorId does not match receiptPublicKey"
    }
    return SubmissionOperatorConfiguration(
        submissionEndpoint = submissionEndpoint,
        receiptPublicKey = receiptPublicKey,
        operatorId = operatorId,
        eventId = eventId,
        eventDefinitionDigest = eventDefinitionDigest,
        validFrom = validFrom,
        validUntil = validUntil,
    )
}

private fun validateSubmissionEndpoint(url: String, allowInsecureLoopbackForTests: Boolean): String {
    val normalized = url.trimEnd('/')
    val parsed = parseEndpointUrl(normalized)
    val loopbackHttp = allowInsecureLoopbackForTests &&
        parsed.scheme == "http" &&
        parsed.host in LOOPBACK_HOSTS &&
        parsed.port != null
    require(parsed.scheme == "https" || loopbackHttp) {
        "submission endpoint must use HTTPS or loopback HTTP"
    }
    require(parsed.query == null && parsed.fragment == null) {
        "submission endpoint must not contain a query or fragment"
    }
    return normalized
}

private data class ParsedEndpoint(
    val scheme: String,
    val host: String,
    val port: Int?,
    val query: String?,
    val fragment: String?,
)

private fun parseEndpointUrl(url: String): ParsedEndpoint {
    val schemeEnd = url.indexOf("://")
    require(schemeEnd > 0) { "submission endpoint URL must have a scheme" }
    val scheme = url.substring(0, schemeEnd).lowercase()
    require(scheme.all { it.isLetterOrDigit() || it == '+' || it == '-' || it == '.' }) {
        "submission endpoint URL has an invalid scheme"
    }
    val authorityStart = schemeEnd + 3
    require(authorityStart < url.length) { "submission endpoint URL has no host" }
    val authorityEnd = url.indexOfFirstFrom(authorityStart) ?: url.length
    val authority = url.substring(authorityStart, authorityEnd)
    require(authority.isNotEmpty() && '@' !in authority && '\\' !in authority) {
        "submission endpoint URL has an invalid authority"
    }

    val host: String
    val port: Int?
    if (authority.startsWith('[')) {
        val closingBracket = authority.indexOf(']')
        require(closingBracket > 1) { "submission endpoint URL has an invalid IPv6 host" }
        host = authority.substring(1, closingBracket).lowercase()
        require(host.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' || it == ':' }) {
            "submission endpoint URL has an invalid IPv6 host"
        }
        port = parsePortSuffix(authority.substring(closingBracket + 1))
    } else {
        require('[' !in authority && ']' !in authority) {
            "submission endpoint URL has an invalid host"
        }
        val colon = authority.indexOf(':')
        if (colon >= 0) {
            require(authority.indexOf(':', colon + 1) < 0) {
                "submission endpoint URL has an invalid host"
            }
            host = authority.substring(0, colon).lowercase()
            port = parsePort(authority.substring(colon + 1))
        } else {
            host = authority.lowercase()
            port = null
        }
        require(host.all { it.isLetterOrDigit() || it == '.' || it == '-' }) {
            "submission endpoint URL has an invalid host"
        }
    }
    require(host.isNotEmpty()) { "submission endpoint URL has no host" }
    val query = url.indexOf('?').takeIf { it >= 0 }?.let { url.substring(it + 1) }
    val fragment = url.indexOf('#').takeIf { it >= 0 }?.let { url.substring(it + 1) }
    return ParsedEndpoint(scheme, host, port, query, fragment)
}

private fun parsePortSuffix(suffix: String): Int? {
    if (suffix.isEmpty()) return null
    require(suffix.startsWith(':')) { "submission endpoint URL has an invalid port" }
    return parsePort(suffix.substring(1))
}

private fun parsePort(port: String): Int {
    require(port.isNotEmpty() && port.all { it in '0'..'9' }) {
        "submission endpoint URL has an invalid port"
    }
    val value = port.toIntOrNull()
    require(value != null && value in 1..65_535) {
        "submission endpoint URL has an invalid port"
    }
    return value
}

private fun String.indexOfFirstFrom(startIndex: Int): Int? {
    for (index in startIndex until length) {
        if (this[index] == '/' || this[index] == '?' || this[index] == '#') return index
    }
    return null
}

private fun String.decodeHex(expectedBytes: Int): ByteArray {
    val source = removePrefix("0x")
    require(source.length == expectedBytes * 2 && source.all { it.isAsciiHexDigit() }) {
        "expected $expectedBytes hexadecimal bytes"
    }
    return ByteArray(expectedBytes) { index ->
        source.substring(index * 2, index * 2 + 2).toInt(16).toByte()
    }
}

private fun String.decodeHexVariable(): ByteArray {
    val source = removePrefix("0x")
    require(source.length % 2 == 0 && source.all { it.isAsciiHexDigit() }) {
        "expected even-length hexadecimal bytes"
    }
    return ByteArray(source.length / 2) { index ->
        source.substring(index * 2, index * 2 + 2).toInt(16).toByte()
    }
}

private fun Char.isAsciiHexDigit(): Boolean =
    this in '0'..'9' || this in 'a'..'f' || this in 'A'..'F'

private val LOOPBACK_HOSTS = setOf("127.0.0.1", "localhost", "::1")

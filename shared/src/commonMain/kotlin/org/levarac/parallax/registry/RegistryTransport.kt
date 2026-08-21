package org.levarac.parallax.registry

internal data class RegistryHttpRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    val body: String? = null,
    val timeoutMillis: Int = 4_000,
) {
    override fun toString(): String =
        "RegistryHttpRequest(method=$method, url=${url.substringBefore('?')}, timeoutMillis=$timeoutMillis)"
}

internal data class RegistryHttpResponse(
    val statusCode: Int,
    val body: String,
    /** Raw response bytes; JSON callers continue to use [body]. */
    val bodyBytes: ByteArray = body.encodeToByteArray(),
)

internal interface RegistryHttpTransport {
    suspend fun execute(request: RegistryHttpRequest): RegistryHttpResponse
}

internal class RegistryTransportTimeoutException(message: String = "registry request timed out") :
    Exception(message)

internal enum class RegistryErrorCode(val wireName: String) {
    INVALID_INPUT("invalid_input"),
    TIMEOUT("timeout"),
    RATE_LIMITED("rate_limited"),
    SERVER_ERROR("server_error"),
    HTTP_ERROR("http_error"),
    PROTOCOL_ERROR("protocol_error"),
    CONTRACT_ERROR("contract_error"),
    PIN_UNAVAILABLE("pin_unavailable"),
    STRICT_PIN_UNSUPPORTED("strict_pin_unsupported"),
    DECODING_ERROR("decoding_error"),
    RESULT_MISMATCH("result_mismatch"),
    NO_ENDPOINT("no_endpoint"),
    CANCELLED("cancelled"),
}

internal class RegistryGatewayException(
    val code: RegistryErrorCode,
    val retryable: Boolean,
    val endpointId: String? = null,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

internal data class ResolvedBlockPin(
    val blockNumber: Long,
    val blockHashHex: String,
    val strict: Boolean,
)

internal data class GatewayRead(
    val context: RegistryEventContext,
    val rawCbor: ByteArray,
    val endpointId: String,
    val eip1898Verified: Boolean,
)

public class RegistryReadPin internal constructor(
    internal val kind: RegistryReadPinKind,
    internal val blockHashHex: String?,
)

internal enum class RegistryReadPinKind {
    SAFE,
    FINALIZED,
    BLOCK_HASH,
}

public fun safeRegistryReadPin(): RegistryReadPin =
    RegistryReadPin(RegistryReadPinKind.SAFE, null)

public fun finalizedRegistryReadPin(): RegistryReadPin =
    RegistryReadPin(RegistryReadPinKind.FINALIZED, null)

public fun strictRegistryReadPin(blockHashHex: String): RegistryReadPin? = try {
    val normalized = blockHashHex.decodeHex(expectedBytes = 32).toPrefixedHex()
    RegistryReadPin(RegistryReadPinKind.BLOCK_HASH, normalized)
} catch (_: IllegalArgumentException) {
    null
}

internal expect fun createPlatformRegistryHttpTransport(): RegistryHttpTransport

internal fun validateReaderAddress(addressHex: String): String {
    val normalized = addressHex.decodeHex(expectedBytes = 20).toPrefixedHex()
    require(normalized != ZERO_ADDRESS_HEX) { "registry reader address must not be zero" }
    return normalized
}

internal fun validateEndpointUrl(
    url: String,
    allowInsecureLoopbackForTests: Boolean = false,
): String {
    val normalized = url.trimEnd('/')
    val parsed = parseRegistryUrl(normalized)
    val productionHttps = parsed.scheme == "https"
    val loopbackHttp = allowInsecureLoopbackForTests &&
        parsed.scheme == "http" &&
        parsed.host in LOOPBACK_HOSTS &&
        parsed.port != null
    require(productionHttps || loopbackHttp) {
        "registry endpoint must use HTTPS or loopback HTTP"
    }
    return normalized
}

private data class ParsedRegistryUrl(
    val scheme: String,
    val host: String,
    val port: Int?,
)

private fun parseRegistryUrl(url: String): ParsedRegistryUrl {
    val schemeEnd = url.indexOf("://")
    require(schemeEnd > 0) { "registry endpoint URL must have a scheme" }
    val scheme = url.substring(0, schemeEnd).lowercase()
    require(scheme.all { it.isLetterOrDigit() || it == '+' || it == '-' || it == '.' }) {
        "registry endpoint URL has an invalid scheme"
    }

    val authorityStart = schemeEnd + 3
    require(authorityStart < url.length) { "registry endpoint URL has no host" }
    val authorityEnd = url.indexOfFirstFrom(authorityStart) ?: url.length
    val authority = url.substring(authorityStart, authorityEnd)
    require(authority.isNotEmpty()) { "registry endpoint URL has no host" }
    require('@' !in authority) { "registry endpoint URL must not contain userinfo" }
    require('\\' !in authority) { "registry endpoint URL contains an invalid host" }

    val host: String
    val port: Int?
    if (authority.startsWith('[')) {
        val closingBracket = authority.indexOf(']')
        require(closingBracket > 1) { "registry endpoint URL has an invalid IPv6 host" }
        host = authority.substring(1, closingBracket).lowercase()
        require(host.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' || it == ':' }) {
            "registry endpoint URL has an invalid IPv6 host"
        }
        val suffix = authority.substring(closingBracket + 1)
        port = parsePortSuffix(suffix)
    } else {
        require('[' !in authority && ']' !in authority) {
            "registry endpoint URL has an invalid host"
        }
        val colon = authority.indexOf(':')
        if (colon >= 0) {
            require(authority.indexOf(':', colon + 1) < 0) {
                "registry endpoint URL has an invalid host"
            }
            host = authority.substring(0, colon).lowercase()
            port = parsePort(authority.substring(colon + 1))
        } else {
            host = authority.lowercase()
            port = null
        }
        require(host.all { it.isLetterOrDigit() || it == '.' || it == '-' }) {
            "registry endpoint URL has an invalid host"
        }
    }
    require(host.isNotEmpty()) { "registry endpoint URL has no host" }
    return ParsedRegistryUrl(scheme, host, port)
}

private fun parsePortSuffix(suffix: String): Int? {
    if (suffix.isEmpty()) return null
    require(suffix.startsWith(':')) { "registry endpoint URL has an invalid port" }
    return parsePort(suffix.substring(1))
}

private fun parsePort(port: String): Int {
    require(port.isNotEmpty() && port.all { it in '0'..'9' }) {
        "registry endpoint URL has an invalid port"
    }
    val value = port.toIntOrNull()
    require(value != null && value in 1..65_535) {
        "registry endpoint URL has an invalid port"
    }
    return value
}

private fun String.indexOfFirstFrom(startIndex: Int): Int? {
    for (index in startIndex until length) {
        if (this[index] == '/' || this[index] == '?' || this[index] == '#') return index
    }
    return null
}

private const val ZERO_ADDRESS_HEX: String = "0x0000000000000000000000000000000000000000"
private val LOOPBACK_HOSTS = setOf("127.0.0.1", "localhost", "::1")

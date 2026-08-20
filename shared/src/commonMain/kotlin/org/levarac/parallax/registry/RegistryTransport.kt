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

internal fun validateEndpointUrl(url: String): String {
    val normalized = url.trimEnd('/')
    val productionHttps = normalized.startsWith("https://")
    val loopbackHttp = normalized.startsWith("http://127.0.0.1:") ||
        normalized.startsWith("http://localhost:") ||
        normalized.startsWith("http://[::1]:")
    require(productionHttps || loopbackHttp) { "registry endpoint must use HTTPS or loopback HTTP" }
    return normalized
}

private const val ZERO_ADDRESS_HEX: String = "0x0000000000000000000000000000000000000000"

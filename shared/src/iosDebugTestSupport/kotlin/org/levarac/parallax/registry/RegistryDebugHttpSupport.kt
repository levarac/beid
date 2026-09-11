package org.levarac.parallax.registry

/** Raw request only. No registry result or verified identity can be injected. */
public class RegistryDebugHttpRequest internal constructor(
    public val method: String,
    public val url: String,
    public val body: String?,
)

public class RegistryDebugHttpResponse(statusCode: Int, bodyBytes: ByteArray) {
    internal val response = RegistryHttpResponse(
        statusCode = statusCode,
        body = bodyBytes.decodeToString(),
        bodyBytes = bodyBytes.copyOf(),
    )
}

/**
 * Debug-only native test instrument. The real RPC decoder, block pin, source
 * key and resolver still run. This does not exercise TLS or network transport.
 * This entire source directory is excluded unless the build explicitly opts
 * into Debug; the Release native-link guard rejects contradictory inputs.
 */
public fun createDebugSepoliaRegistryClient(
    readerAddressHex: String,
    exchange: (RegistryDebugHttpRequest) -> RegistryDebugHttpResponse,
): RegistryClient? = createSepoliaRegistryClientWithTransport(
    readerAddressHex = readerAddressHex,
    transportFactory = {
        object : RegistryHttpTransport {
            override suspend fun execute(request: RegistryHttpRequest): RegistryHttpResponse =
                exchange(RegistryDebugHttpRequest(request.method, request.url, request.body)).response
        }
    },
)

package org.levarac.parallax.registry

import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject

internal class EtherscanRestAdapter(
    private val chainId: Long,
    readerAddressHex: String,
    private val apiKey: String,
    private val transport: RegistryHttpTransport,
    endpointUrl: String = "https://api.etherscan.io/v2/api",
) {
    internal val endpointId: String = "etherscan-v2"
    private val endpoint: String = validateEndpointUrl(endpointUrl)
    private val readerAddress: String = validateReaderAddress(readerAddressHex)

    init {
        require(chainId > 0) { "chainId must be positive" }
        require(apiKey.isNotBlank()) { "Etherscan API key must not be blank" }
    }

    internal suspend fun read(eventId: ByteArray, pin: ResolvedBlockPin): GatewayRead {
        if (pin.strict) {
            throw RegistryGatewayException(
                RegistryErrorCode.STRICT_PIN_UNSUPPORTED,
                retryable = false,
                endpointId = endpointId,
                message = "Etherscan is not eligible for strict block-hash reads",
            )
        }
        val calldata = EthereumAbiCodec.encodeGetEventForClient(eventId)
        val callUrl = buildString {
            append(endpoint)
            append("?chainid=")
            append(chainId)
            append("&module=proxy&action=eth_call&to=")
            append(readerAddress)
            append("&data=")
            append(calldata)
            append("&tag=0x")
            append(pin.blockNumber.toString(16))
            append("&apikey=")
            append(percentEncode(apiKey))
        }
        val envelope = executeProxy(callUrl)
        val result = requireProxyResult(envelope)
        val resultHex = (result as? JsonPrimitive)?.contentOrNull
            ?: throw failure(RegistryErrorCode.PROTOCOL_ERROR, false, "Etherscan result is missing")
        val rawCbor = try {
            EthereumAbiCodec.decodeDynamicBytes(resultHex)
        } catch (error: IllegalArgumentException) {
            throw failure(RegistryErrorCode.DECODING_ERROR, false, "invalid Etherscan ABI result", error)
        }
        val context = try {
            RegistryCborCodec.decode(rawCbor)
        } catch (error: IllegalArgumentException) {
            throw failure(RegistryErrorCode.DECODING_ERROR, false, "invalid Etherscan CBOR result", error)
        }
        verifyPinnedBlockHeader(pin)
        return GatewayRead(context, rawCbor, endpointId, eip1898Verified = false)
    }

    private suspend fun verifyPinnedBlockHeader(pin: ResolvedBlockPin) {
        val headerUrl = buildString {
            append(endpoint)
            append("?chainid=")
            append(chainId)
            append("&module=proxy&action=eth_getBlockByNumber&tag=0x")
            append(pin.blockNumber.toString(16))
            append("&boolean=false&apikey=")
            append(percentEncode(apiKey))
        }
        val header = requireProxyResult(executeProxy(headerUrl)) as? JsonObject
            ?: throw failure(RegistryErrorCode.PROTOCOL_ERROR, false, "Etherscan block header is missing")
        val numberHex = (header["number"] as? JsonPrimitive)?.contentOrNull
            ?: throw failure(RegistryErrorCode.PROTOCOL_ERROR, false, "Etherscan block number is missing")
        val hashHex = (header["hash"] as? JsonPrimitive)?.contentOrNull
            ?: throw failure(RegistryErrorCode.PROTOCOL_ERROR, false, "Etherscan block hash is missing")
        val number = try {
            decodeHexQuantity(numberHex)
        } catch (error: IllegalArgumentException) {
            throw failure(RegistryErrorCode.PROTOCOL_ERROR, false, "invalid Etherscan block number", error)
        }
        val hash = try {
            hashHex.decodeHex(expectedBytes = 32).toPrefixedHex()
        } catch (error: IllegalArgumentException) {
            throw failure(RegistryErrorCode.PROTOCOL_ERROR, false, "invalid Etherscan block hash", error)
        }
        if (number != pin.blockNumber || hash != pin.blockHashHex) {
            throw failure(
                RegistryErrorCode.RESULT_MISMATCH,
                retryable = false,
                message = "Etherscan block number no longer matches the pinned block hash",
            )
        }
    }

    private suspend fun executeProxy(url: String): JsonObject {
        val response = try {
            transport.execute(RegistryHttpRequest(method = "GET", url = url))
        } catch (error: RegistryTransportTimeoutException) {
            throw failure(RegistryErrorCode.TIMEOUT, retryable = true, "Etherscan request timed out", error)
        } catch (error: CancellationException) {
            throw error
        } catch (error: IllegalArgumentException) {
            throw failure(
                RegistryErrorCode.PROTOCOL_ERROR,
                retryable = false,
                message = "Etherscan transport rejected the response",
                cause = error,
            )
        } catch (error: Throwable) {
            throw failure(RegistryErrorCode.HTTP_ERROR, retryable = false, "Etherscan transport failed", error)
        }
        classifyHttpStatus(response.statusCode)
        val envelope = try {
            JSON.parseToJsonElement(response.body).jsonObject
        } catch (error: Throwable) {
            throw failure(RegistryErrorCode.PROTOCOL_ERROR, false, "Etherscan returned malformed JSON", error)
        }
        classifyEtherscanStatusEnvelope(envelope)
        if ((envelope["jsonrpc"] as? JsonPrimitive)?.contentOrNull != "2.0") {
            throw failure(RegistryErrorCode.PROTOCOL_ERROR, false, "invalid Etherscan JSON-RPC version")
        }
        if ((envelope["id"] as? JsonPrimitive)?.contentOrNull != "1") {
            throw failure(RegistryErrorCode.PROTOCOL_ERROR, false, "invalid Etherscan JSON-RPC response ID")
        }
        return envelope
    }

    private fun requireProxyResult(envelope: JsonObject): JsonElement {
        val result = envelope["result"]
        val error = envelope["error"]
        if (error != null && error !is JsonNull) {
            throw failure(RegistryErrorCode.CONTRACT_ERROR, false, "Etherscan proxy returned a JSON-RPC error")
        }
        if (result == null) {
            throw failure(RegistryErrorCode.PROTOCOL_ERROR, false, "Etherscan result is missing")
        }
        if (result is JsonNull) {
            throw failure(RegistryErrorCode.PIN_UNAVAILABLE, false, "Etherscan block result is unavailable")
        }
        return result
    }

    private fun classifyHttpStatus(statusCode: Int) {
        when {
            statusCode in 200..299 -> Unit
            statusCode == 429 -> throw failure(RegistryErrorCode.RATE_LIMITED, true, "Etherscan rate limited the request")
            statusCode >= 500 -> throw failure(RegistryErrorCode.SERVER_ERROR, true, "Etherscan server failed")
            else -> throw failure(RegistryErrorCode.HTTP_ERROR, false, "Etherscan returned HTTP $statusCode")
        }
    }

    private fun classifyEtherscanStatusEnvelope(envelope: JsonObject) {
        val statusElement = envelope["status"] ?: return
        val status = (statusElement as? JsonPrimitive)?.contentOrNull
            ?: throw failure(RegistryErrorCode.PROTOCOL_ERROR, false, "Etherscan status must be a string")
        if (status != "0") return
        val resultElement = envelope["result"]
        val result = (resultElement as? JsonPrimitive)?.contentOrNull
            ?: throw failure(RegistryErrorCode.PROTOCOL_ERROR, false, "Etherscan error result must be a string")
        val retryable = result.contains("rate limit", ignoreCase = true) ||
            result.contains("timeout", ignoreCase = true) ||
            result.contains("server busy", ignoreCase = true)
        val code = if (result.contains("rate limit", ignoreCase = true)) {
            RegistryErrorCode.RATE_LIMITED
        } else if (retryable) {
            RegistryErrorCode.SERVER_ERROR
        } else {
            RegistryErrorCode.HTTP_ERROR
        }
        throw failure(code, retryable, "Etherscan rejected the request")
    }

    private fun failure(
        code: RegistryErrorCode,
        retryable: Boolean,
        message: String,
        cause: Throwable? = null,
    ): RegistryGatewayException = RegistryGatewayException(
        code,
        retryable,
        endpointId,
        message,
        cause,
    )

    private companion object {
        val JSON: Json = Json { ignoreUnknownKeys = true }
    }
}

private fun percentEncode(value: String): String = buildString {
    val unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    for (byte in value.encodeToByteArray()) {
        val unsigned = byte.toInt() and 0xff
        val character = unsigned.toChar()
        if (character in unreserved) {
            append(character)
        } else {
            append('%')
            append("0123456789ABCDEF"[unsigned ushr 4])
            append("0123456789ABCDEF"[unsigned and 0x0f])
        }
    }
}

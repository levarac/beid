package org.levarac.parallax.registry

import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull

internal class JsonRpcEthCallAdapter(
    endpointUrl: String,
    readerAddressHex: String,
    private val transport: RegistryHttpTransport,
) {
    internal val endpointId: String = validateEndpointUrl(endpointUrl)
    private val readerAddress: String = validateReaderAddress(readerAddressHex)

    internal suspend fun resolvePin(pin: RegistryReadPin): ResolvedBlockPin {
        val (method, parameter) = when (pin.kind) {
            RegistryReadPinKind.SAFE -> "eth_getBlockByNumber" to "\"safe\""
            RegistryReadPinKind.FINALIZED -> "eth_getBlockByNumber" to "\"finalized\""
            RegistryReadPinKind.BLOCK_HASH ->
                "eth_getBlockByHash" to "\"${pin.blockHashHex}\""
        }
        val body = """{"jsonrpc":"2.0","id":1,"method":"$method","params":[$parameter,false]}"""
        val result = executeJsonRpc(body, expectedId = 1)
        return decodeBlockHeader(result) { number, blockHashHex ->
            if (pin.kind == RegistryReadPinKind.BLOCK_HASH) {
                if (blockHashHex != pin.blockHashHex) {
                    throw protocolFailure("resolved block hash does not match the strict pin")
                }
            }
            ResolvedBlockPin(
                blockNumber = number,
                blockHashHex = blockHashHex,
                strict = pin.kind == RegistryReadPinKind.BLOCK_HASH,
            )
        }
    }

    internal suspend fun resolveCanonicalBlockAtNumber(blockNumber: Long): ResolvedBlockPin {
        require(blockNumber >= 0) { "blockNumber must not be negative" }
        val blockNumberHex = "0x${blockNumber.toString(16)}"
        val body =
            """{"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":["$blockNumberHex",false]}"""
        val result = executeJsonRpc(body, expectedId = 1)
        return decodeBlockHeader(result) { resolvedNumber, blockHashHex ->
            if (resolvedNumber != blockNumber) {
                throw protocolFailure("resolved block number does not match the requested number")
            }
            ResolvedBlockPin(
                blockNumber = resolvedNumber,
                blockHashHex = blockHashHex,
                strict = true,
            )
        }
    }

    internal suspend fun read(eventId: ByteArray, pin: ResolvedBlockPin): GatewayRead {
        val calldata = EthereumAbiCodec.encodeGetEventForClient(eventId)
        val body = """{"jsonrpc":"2.0","id":2,"method":"eth_call","params":[{"to":"$readerAddress","input":"$calldata"},{"blockHash":"${pin.blockHashHex}","requireCanonical":true}]}"""
        val result = executeJsonRpc(body, expectedId = 2)
        val resultHex = (result as? JsonPrimitive)?.contentOrNull
            ?: throw protocolFailure("eth_call result must be a hex string")
        val rawCbor = try {
            EthereumAbiCodec.decodeDynamicBytes(resultHex)
        } catch (error: IllegalArgumentException) {
            throw decodeFailure("invalid ABI bytes result", error)
        }
        val context = try {
            RegistryCborCodec.decode(rawCbor)
        } catch (error: IllegalArgumentException) {
            throw decodeFailure("invalid registry CBOR result", error)
        }
        return GatewayRead(context, rawCbor, endpointId, eip1898Verified = true)
    }

    private suspend fun executeJsonRpc(body: String, expectedId: Long): JsonElement {
        val response = try {
            transport.execute(
                RegistryHttpRequest(
                    method = "POST",
                    url = endpointId,
                    headers = mapOf("Content-Type" to "application/json"),
                    body = body,
                ),
            )
        } catch (error: RegistryTransportTimeoutException) {
            throw RegistryGatewayException(
                RegistryErrorCode.TIMEOUT,
                retryable = true,
                endpointId = endpointId,
                message = "registry RPC request timed out",
                cause = error,
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: IllegalArgumentException) {
            throw RegistryGatewayException(
                RegistryErrorCode.PROTOCOL_ERROR,
                retryable = false,
                endpointId = endpointId,
                message = "registry RPC transport rejected the response",
                cause = error,
            )
        } catch (error: Throwable) {
            throw RegistryGatewayException(
                RegistryErrorCode.HTTP_ERROR,
                retryable = false,
                endpointId = endpointId,
                message = "registry RPC transport failed",
                cause = error,
            )
        }
        classifyHttpStatus(response.statusCode)
        val envelope = parseJsonObject(response.body)
        return try {
            requireJsonRpcEnvelope(envelope, expectedId)
            envelope["error"]?.takeUnless { it is JsonNull }?.let { error ->
                val errorObject = error as? JsonObject
                    ?: throw protocolFailure("JSON-RPC error must be an object")
                val codeElement = errorObject["code"]
                val code = (codeElement as? JsonPrimitive)?.longOrNull
                if (codeElement != null && code == null) {
                    throw protocolFailure("JSON-RPC error code must be an integer")
                }
                val messageElement = errorObject["message"]
                val message = (messageElement as? JsonPrimitive)?.contentOrNull
                    ?: if (messageElement == null) "JSON-RPC error" else {
                        throw protocolFailure("JSON-RPC error message must be a string")
                    }
                val mapped = when (code) {
                    -32_001L -> RegistryErrorCode.PIN_UNAVAILABLE
                    -32_000L -> RegistryErrorCode.PIN_UNAVAILABLE
                    -32_602L -> RegistryErrorCode.STRICT_PIN_UNSUPPORTED
                    else -> RegistryErrorCode.CONTRACT_ERROR
                }
                throw RegistryGatewayException(
                    mapped,
                    retryable = false,
                    endpointId = endpointId,
                    message = "registry RPC rejected the read: $message",
                )
            }
            envelope["result"] ?: throw protocolFailure("JSON-RPC result is missing")
        } catch (error: RegistryGatewayException) {
            throw error
        } catch (error: IllegalArgumentException) {
            throw protocolFailure("registry RPC returned an invalid JSON-RPC envelope", error)
        }
    }

    private fun classifyHttpStatus(statusCode: Int) {
        when {
            statusCode in 200..299 -> Unit
            statusCode == 429 -> throw RegistryGatewayException(
                RegistryErrorCode.RATE_LIMITED,
                retryable = true,
                endpointId = endpointId,
                message = "registry RPC rate limited the request",
            )
            statusCode >= 500 -> throw RegistryGatewayException(
                RegistryErrorCode.SERVER_ERROR,
                retryable = true,
                endpointId = endpointId,
                message = "registry RPC server failed",
            )
            else -> throw RegistryGatewayException(
                RegistryErrorCode.HTTP_ERROR,
                retryable = false,
                endpointId = endpointId,
                message = "registry RPC returned HTTP $statusCode",
            )
        }
    }

    private fun parseJsonObject(body: String): JsonObject = try {
        JSON.parseToJsonElement(body).jsonObject
    } catch (error: Throwable) {
        throw protocolFailure("registry RPC returned malformed JSON", error)
    }

    private fun requireJsonRpcEnvelope(envelope: JsonObject, expectedId: Long) {
        if ((envelope["jsonrpc"] as? JsonPrimitive)?.contentOrNull != "2.0") {
            throw protocolFailure("invalid JSON-RPC version")
        }
        if ((envelope["id"] as? JsonPrimitive)?.longOrNull != expectedId) {
            throw protocolFailure("JSON-RPC response ID does not match the request")
        }
        val hasResult = envelope.containsKey("result")
        val hasError = envelope.containsKey("error") && envelope["error"] !is JsonNull
        if (hasResult == hasError) {
            throw protocolFailure("JSON-RPC response must contain exactly one result or error")
        }
    }

    private fun requireResultObject(result: JsonElement, label: String): JsonObject {
        if (result is JsonNull) {
            throw RegistryGatewayException(
                RegistryErrorCode.PIN_UNAVAILABLE,
                retryable = false,
                endpointId = endpointId,
                message = "$label was not found",
            )
        }
        return result as? JsonObject ?: throw protocolFailure("$label result must be an object")
    }

    private fun decodeBlockHeader(
        result: JsonElement,
        transform: (blockNumber: Long, blockHashHex: String) -> ResolvedBlockPin,
    ): ResolvedBlockPin = try {
        val header = requireResultObject(result, "block header")
        val numberHex = header.requiredString("number")
        val blockHashHex = header.requiredString("hash").decodeHex(expectedBytes = 32).toPrefixedHex()
        transform(decodeHexQuantity(numberHex), blockHashHex)
    } catch (error: RegistryGatewayException) {
        throw error
    } catch (error: IllegalArgumentException) {
        throw protocolFailure("registry RPC returned an invalid block header", error)
    }

    private fun JsonObject.requiredString(name: String): String =
        (this[name] as? JsonPrimitive)?.contentOrNull
            ?: throw protocolFailure("block header is missing $name")

    private fun protocolFailure(message: String, cause: Throwable? = null): RegistryGatewayException =
        RegistryGatewayException(
            RegistryErrorCode.PROTOCOL_ERROR,
            retryable = false,
            endpointId = endpointId,
            message = message,
            cause = cause,
        )

    private fun decodeFailure(message: String, cause: Throwable): RegistryGatewayException =
        RegistryGatewayException(
            RegistryErrorCode.DECODING_ERROR,
            retryable = false,
            endpointId = endpointId,
            message = message,
            cause = cause,
        )

    private companion object {
        val JSON: Json = Json { ignoreUnknownKeys = false }
    }
}

internal fun decodeHexQuantity(value: String): Long {
    require(value.startsWith("0x")) { "Ethereum quantity must have a 0x prefix" }
    val digits = value.substring(2)
    require(digits.isNotEmpty()) { "Ethereum quantity must not be empty" }
    require(digits == "0" || !digits.startsWith('0')) { "Ethereum quantity must be minimally encoded" }
    require(digits.length <= 16) { "Ethereum quantity exceeds the supported range" }
    val parsed = digits.toULongOrNull(16) ?: throw IllegalArgumentException("invalid Ethereum quantity")
    require(parsed <= Long.MAX_VALUE.toULong()) { "Ethereum quantity exceeds the supported signed range" }
    return parsed.toLong()
}

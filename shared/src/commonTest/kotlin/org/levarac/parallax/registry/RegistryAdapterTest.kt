package org.levarac.parallax.registry

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlin.test.fail

class RegistryAdapterTest {
    @Test
    fun pinFactoriesExposeSafeFinalizedAndNormalizedStrictPins() {
        val safe = safeRegistryReadPin()
        val finalized = finalizedRegistryReadPin()
        val strict = assertNotNull(strictRegistryReadPin("0X" + "AA".repeat(32)))

        assertEquals(RegistryReadPinKind.SAFE, safe.kind)
        assertNull(safe.blockHashHex)
        assertEquals(RegistryReadPinKind.FINALIZED, finalized.kind)
        assertNull(finalized.blockHashHex)
        assertEquals(RegistryReadPinKind.BLOCK_HASH, strict.kind)
        assertEquals("0x" + "aa".repeat(32), strict.blockHashHex)
    }

    @Test
    fun exportedFactoriesRejectMalformedConfigurationWithoutThrowing() {
        assertNull(strictRegistryReadPin("0x1234"))
        assertNull(strictRegistryReadPin("0x" + "zz".repeat(32)))
        assertNull(createSepoliaRegistryClient("not-an-address", null))
        assertNull(createSepoliaRegistryClient("0x" + "00".repeat(20), null))
    }

    @Test
    fun safePinResolvesHeaderThenReadsAtItsCanonicalBlockHash() = runTest {
        val transport = RecordingRegistryTransport(
            RegistryTestFixtures.headerResponse(),
            RegistryTestFixtures.callResponse(),
        )
        val adapter = JsonRpcEthCallAdapter(
            RegistryTestFixtures.ENDPOINT,
            RegistryTestFixtures.READER,
            transport,
        )

        val pin = adapter.resolvePin(safeRegistryReadPin())
        val read = adapter.read(RegistryTestFixtures.eventId, pin)

        assertEquals(0x1234L, pin.blockNumber)
        assertEquals(RegistryTestFixtures.BLOCK_HASH, pin.blockHashHex)
        assertFalse(pin.strict)
        assertEquals(RegistryTestFixtures.ENDPOINT, read.endpointId)
        assertEquals(RegistryTestFixtures.LATEST_DIGEST, read.context.latestDefinitionDigestHex)
        assertContentEquals(RegistryTestFixtures.cbor(), read.rawCbor)

        val headerRequest = transport.requests[0]
        assertEquals("POST", headerRequest.method)
        assertEquals(RegistryTestFixtures.ENDPOINT, headerRequest.url)
        assertEquals("application/json", headerRequest.headers["Content-Type"])
        assertEquals(4_000, headerRequest.timeoutMillis)
        val headerJson = JSON.parseToJsonElement(headerRequest.body!!).jsonObject
        assertEquals("eth_getBlockByNumber", headerJson.string("method"))
        assertEquals("safe", headerJson["params"]!!.jsonArray[0].jsonPrimitive.content)
        assertFalse(headerJson["params"]!!.jsonArray[1].jsonPrimitive.boolean)

        val callJson = JSON.parseToJsonElement(transport.requests[1].body!!).jsonObject
        assertEquals("eth_call", callJson.string("method"))
        val callParams = callJson["params"]!!.jsonArray
        assertEquals(RegistryTestFixtures.READER, callParams[0].jsonObject.string("to"))
        assertEquals(
            "0xf8cd791d" + RegistryTestFixtures.eventId.toPrefixedHex().removePrefix("0x"),
            callParams[0].jsonObject.string("input"),
        )
        assertEquals(RegistryTestFixtures.BLOCK_HASH, callParams[1].jsonObject.string("blockHash"))
        assertTrue(callParams[1].jsonObject["requireCanonical"]!!.jsonPrimitive.boolean)
    }

    @Test
    fun finalizedPinUsesFinalizedHeaderTag() = runTest {
        val transport = RecordingRegistryTransport(RegistryTestFixtures.headerResponse())
        val adapter = JsonRpcEthCallAdapter(
            RegistryTestFixtures.ENDPOINT,
            RegistryTestFixtures.READER,
            transport,
        )

        adapter.resolvePin(finalizedRegistryReadPin())

        val request = JSON.parseToJsonElement(transport.requests.single().body!!).jsonObject
        assertEquals("finalized", request["params"]!!.jsonArray[0].jsonPrimitive.content)
    }

    @Test
    fun strictPinResolvesByHashAndEtherscanRejectsItBeforeHttp() = runTest {
        val directTransport = RecordingRegistryTransport(RegistryTestFixtures.headerResponse())
        val direct = JsonRpcEthCallAdapter(
            RegistryTestFixtures.ENDPOINT,
            RegistryTestFixtures.READER,
            directTransport,
        )

        val pin = direct.resolvePin(requireNotNull(strictRegistryReadPin(RegistryTestFixtures.BLOCK_HASH)))

        assertTrue(pin.strict)
        val request = JSON.parseToJsonElement(directTransport.requests.single().body!!).jsonObject
        assertEquals("eth_getBlockByHash", request.string("method"))
        assertEquals(RegistryTestFixtures.BLOCK_HASH, request["params"]!!.jsonArray[0].jsonPrimitive.content)

        val etherscanTransport = RecordingRegistryTransport(emptyList())
        val etherscan = EtherscanRestAdapter(
            chainId = 11_155_111,
            readerAddressHex = RegistryTestFixtures.READER,
            apiKey = "public-api-key",
            transport = etherscanTransport,
        )
        val failure = gatewayFailure { etherscan.read(RegistryTestFixtures.eventId, pin) }
        assertEquals(RegistryErrorCode.STRICT_PIN_UNSUPPORTED, failure.code)
        assertFalse(failure.retryable)
        assertTrue(etherscanTransport.requests.isEmpty())
    }

    @Test
    fun etherscanUsesDocumentedV2QueryAndRedactsApiKeyFromDiagnostics() = runTest {
        val apiKey = "public-api-key"
        val transport = RecordingRegistryTransport(
            RegistryTestFixtures.etherscanResponse(),
            RegistryTestFixtures.headerResponse(),
        )
        val adapter = EtherscanRestAdapter(
            chainId = 11_155_111,
            readerAddressHex = RegistryTestFixtures.READER,
            apiKey = apiKey,
            transport = transport,
        )

        val read = adapter.read(
            RegistryTestFixtures.eventId,
            ResolvedBlockPin(0x1234, RegistryTestFixtures.BLOCK_HASH, strict = false),
        )

        assertEquals("etherscan-v2", read.endpointId)
        assertContentEquals(RegistryTestFixtures.cbor(), read.rawCbor)
        val request = transport.requests[0]
        assertEquals("GET", request.method)
        assertNull(request.body)
        val query = request.url.substringAfter('?').split('&').associate {
            it.substringBefore('=') to it.substringAfter('=')
        }
        assertEquals("11155111", query["chainid"])
        assertEquals("proxy", query["module"])
        assertEquals("eth_call", query["action"])
        assertEquals(RegistryTestFixtures.READER, query["to"])
        assertEquals(
            "0xf8cd791d" + RegistryTestFixtures.eventId.toPrefixedHex().removePrefix("0x"),
            query["data"],
        )
        assertEquals("0x1234", query["tag"])
        assertEquals(apiKey, query["apikey"])
        assertFalse(request.toString().contains(apiKey), "request diagnostics must redact the API key")

        val headerQuery = transport.requests[1].url.substringAfter('?').split('&').associate {
            it.substringBefore('=') to it.substringAfter('=')
        }
        assertEquals("eth_getBlockByNumber", headerQuery["action"])
        assertEquals("0x1234", headerQuery["tag"])
        assertEquals("false", headerQuery["boolean"])
        assertEquals(apiKey, headerQuery["apikey"])
        assertFalse(transport.requests[1].toString().contains(apiKey))
    }

    @Test
    fun etherscanRejectsAReorgedNumberPinAfterTheCall() = runTest {
        val transport = RecordingRegistryTransport(
            RegistryTestFixtures.etherscanResponse(),
            RegistryTestFixtures.headerResponse(blockHash = RegistryTestFixtures.OTHER_BLOCK_HASH),
        )
        val adapter = EtherscanRestAdapter(
            chainId = 11_155_111,
            readerAddressHex = RegistryTestFixtures.READER,
            apiKey = "public-api-key",
            transport = transport,
        )

        val failure = gatewayFailure {
            adapter.read(
                RegistryTestFixtures.eventId,
                ResolvedBlockPin(0x1234, RegistryTestFixtures.BLOCK_HASH, strict = false),
            )
        }

        assertEquals(RegistryErrorCode.RESULT_MISMATCH, failure.code)
        assertFalse(failure.retryable)
        assertEquals(2, transport.requests.size)
    }

    @Test
    fun rpcCancellationIsNeverReclassifiedAsAnHttpFailure() = runTest {
        val transport = RecordingRegistryTransport(
            listOf(TransportOutcome.Fail(CancellationException("cancelled"))),
        )
        val adapter = JsonRpcEthCallAdapter(
            RegistryTestFixtures.ENDPOINT,
            RegistryTestFixtures.READER,
            transport,
        )

        assertFailsWith<CancellationException> {
            adapter.resolvePin(safeRegistryReadPin())
        }
    }

    @Test
    fun etherscanCancellationIsNeverReclassifiedAsAnHttpFailure() = runTest {
        val transport = RecordingRegistryTransport(
            listOf(TransportOutcome.Fail(CancellationException("cancelled"))),
        )
        val adapter = EtherscanRestAdapter(
            chainId = 11_155_111,
            readerAddressHex = RegistryTestFixtures.READER,
            apiKey = "public-api-key",
            transport = transport,
        )

        assertFailsWith<CancellationException> {
            adapter.read(
                RegistryTestFixtures.eventId,
                ResolvedBlockPin(0x1234, RegistryTestFixtures.BLOCK_HASH, strict = false),
            )
        }
    }

    @Test
    fun boundedTransportRejectionsAreProtocolFailuresForBothAdapters() = runTest {
        val rpcTransport = RecordingRegistryTransport(
            listOf(TransportOutcome.Fail(IllegalArgumentException("response exceeds limit"))),
        )
        val rpc = JsonRpcEthCallAdapter(
            RegistryTestFixtures.ENDPOINT,
            RegistryTestFixtures.READER,
            rpcTransport,
        )
        val rpcFailure = gatewayFailure { rpc.resolvePin(safeRegistryReadPin()) }

        val etherscanTransport = RecordingRegistryTransport(
            listOf(TransportOutcome.Fail(IllegalArgumentException("response exceeds limit"))),
        )
        val etherscan = EtherscanRestAdapter(
            chainId = 11_155_111,
            readerAddressHex = RegistryTestFixtures.READER,
            apiKey = "public-api-key",
            transport = etherscanTransport,
        )
        val etherscanFailure = gatewayFailure {
            etherscan.read(
                RegistryTestFixtures.eventId,
                ResolvedBlockPin(0x1234, RegistryTestFixtures.BLOCK_HASH, strict = false),
            )
        }

        assertEquals(RegistryErrorCode.PROTOCOL_ERROR, rpcFailure.code)
        assertEquals(RegistryErrorCode.PROTOCOL_ERROR, etherscanFailure.code)
        assertFalse(rpcFailure.retryable)
        assertFalse(etherscanFailure.retryable)
    }

    private companion object {
        val JSON: Json = Json
    }
}

internal suspend fun gatewayFailure(block: suspend () -> Unit): RegistryGatewayException {
    try {
        block()
    } catch (failure: RegistryGatewayException) {
        return failure
    }
    fail("expected RegistryGatewayException")
}

private fun kotlinx.serialization.json.JsonObject.string(name: String): String =
    this[name]!!.jsonPrimitive.content

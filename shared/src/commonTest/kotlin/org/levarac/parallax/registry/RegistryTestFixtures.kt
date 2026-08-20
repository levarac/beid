package org.levarac.parallax.registry

internal object RegistryTestFixtures {
    internal const val ENDPOINT: String = "https://rpc.example"
    internal const val SECONDARY_ENDPOINT: String = "https://rpc-2.example"
    internal const val READER: String = "0x1111111111111111111111111111111111111111"
    internal const val BLOCK_HASH: String =
        "0x2222222222222222222222222222222222222222222222222222222222222222"
    internal const val OTHER_BLOCK_HASH: String =
        "0x2323232323232323232323232323232323232323232323232323232323232323"
    internal const val LATEST_DIGEST: String =
        "0x4444444444444444444444444444444444444444444444444444444444444444"

    internal val eventId: ByteArray = ByteArray(32).also { it[31] = 1 }

    internal fun cbor(definitionByte: Int = 0x44): ByteArray = buildList<Byte> {
        byte(0xa3) // { 1: schema, 2: registration, 3: definitionMeta }
        byte(0x01)
        byte(0x01)
        byte(0x02)
        byte(0xa4)
        byte(0x01)
        byteString(20, 0x11)
        byte(0x02)
        byteString(20, 0x22)
        byte(0x03)
        byteString(32, 0x33)
        byte(0x04)
        byte(0x18)
        byte(0x64) // registeredAt = 100
        byte(0x03)
        byte(0xa3)
        byte(0x01)
        byte(0x01) // HAS_DEFINITIONS
        byte(0x02)
        byte(0x01) // latestSequence
        byte(0x03)
        byte(0x81)
        byte(0x86)
        byte(0x01)
        byteString(32, 0x00)
        byteString(32, definitionByte)
        unsigned16(2_000)
        unsigned16(3_000)
        unsigned16(1_900)
    }.toByteArray()

    internal fun abiResult(cbor: ByteArray = cbor()): String {
        val paddedLength = ((cbor.size + 31) / 32) * 32
        val encoded = ByteArray(64 + paddedLength)
        encoded[31] = 0x20.toByte()
        writeIntWord(encoded, 32, cbor.size)
        cbor.copyInto(encoded, destinationOffset = 64)
        return encoded.toPrefixedHex()
    }

    internal fun headerResponse(
        id: Int = 1,
        blockHash: String = BLOCK_HASH,
        blockNumberHex: String = "0x1234",
    ): RegistryHttpResponse = RegistryHttpResponse(
        statusCode = 200,
        body = """{"jsonrpc":"2.0","id":$id,"result":{"number":"$blockNumberHex","hash":"$blockHash"}}""",
    )

    internal fun callResponse(cbor: ByteArray = cbor()): RegistryHttpResponse = RegistryHttpResponse(
        statusCode = 200,
        body = """{"jsonrpc":"2.0","id":2,"result":"${abiResult(cbor)}"}""",
    )

    internal fun etherscanResponse(cbor: ByteArray = cbor()): RegistryHttpResponse = RegistryHttpResponse(
        statusCode = 200,
        body = """{"jsonrpc":"2.0","id":1,"result":"${abiResult(cbor)}"}""",
    )
}

internal sealed interface TransportOutcome {
    data class Respond(val response: RegistryHttpResponse) : TransportOutcome
    data class Fail(val failure: Throwable) : TransportOutcome
}

internal class RecordingRegistryTransport(
    outcomes: List<TransportOutcome>,
) : RegistryHttpTransport {
    internal constructor(vararg responses: RegistryHttpResponse) : this(
        responses.map(TransportOutcome::Respond),
    )

    internal val requests: MutableList<RegistryHttpRequest> = mutableListOf()
    private val remaining: ArrayDeque<TransportOutcome> = ArrayDeque(outcomes)

    override suspend fun execute(request: RegistryHttpRequest): RegistryHttpResponse {
        requests += request
        return when (val outcome = remaining.removeFirstOrNull()) {
            is TransportOutcome.Respond -> outcome.response
            is TransportOutcome.Fail -> throw outcome.failure
            null -> error("unexpected registry HTTP request: ${request.method} ${request.url}")
        }
    }
}

private fun MutableList<Byte>.byte(value: Int) {
    add(value.toByte())
}

private fun MutableList<Byte>.byteString(size: Int, value: Int) {
    if (size < 24) {
        byte(0x40 + size)
    } else {
        byte(0x58)
        byte(size)
    }
    repeat(size) { byte(value) }
}

private fun MutableList<Byte>.unsigned16(value: Int) {
    byte(0x19)
    byte(value ushr 8)
    byte(value)
}

private fun writeIntWord(destination: ByteArray, offset: Int, value: Int) {
    destination[offset + 28] = (value ushr 24).toByte()
    destination[offset + 29] = (value ushr 16).toByte()
    destination[offset + 30] = (value ushr 8).toByte()
    destination[offset + 31] = value.toByte()
}

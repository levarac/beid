package org.levarac.parallax.registry

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class EthereumAbiCodecTest {
    @Test
    fun getEventForClientCalldataUsesTheAgreedSelectorAndExactEventIdWord() {
        val eventId = ByteArray(32) { index -> index.toByte() }

        val calldata = EthereumAbiCodec.encodeGetEventForClient(eventId)

        assertEquals(
            "0xf8cd791d000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
            calldata,
        )
    }

    @Test
    fun getEventForClientRejectsEventIdsThatAreNotExactlyOneAbiWord() {
        assertFailsWith<IllegalArgumentException> {
            EthereumAbiCodec.encodeGetEventForClient(ByteArray(31))
        }
        assertFailsWith<IllegalArgumentException> {
            EthereumAbiCodec.encodeGetEventForClient(ByteArray(33))
        }
    }

    @Test
    fun dynamicBytesDecodesAnExactAbiTupleWithZeroPadding() {
        val result = abiDynamicBytesResult("deadbe")

        assertContentEquals(
            "deadbe".codecHexToByteArray(),
            EthereumAbiCodec.decodeDynamicBytes(result),
        )
    }

    @Test
    fun dynamicBytesAcceptsAZeroLengthPayloadWithoutInventingADataWord() {
        val result = "0x${abiWord(32)}${abiWord(0)}"

        assertContentEquals(ByteArray(0), EthereumAbiCodec.decodeDynamicBytes(result))
    }

    @Test
    fun dynamicBytesRejectsAnOffsetThatDoesNotPointToTheLengthWord() {
        val valid = abiDynamicBytesResult("deadbe")

        assertFailsWith<IllegalArgumentException> {
            EthereumAbiCodec.decodeDynamicBytes(valid.replaceRange(2, 66, abiWord(64)))
        }
        assertFailsWith<IllegalArgumentException> {
            EthereumAbiCodec.decodeDynamicBytes(valid.replaceRange(2, 66, abiWord(31)))
        }
    }

    @Test
    fun dynamicBytesRejectsTruncatedPayloadOrPadding() {
        val twoWordPayload = abiDynamicBytesResult("ab".repeat(33))

        assertFailsWith<IllegalArgumentException> {
            EthereumAbiCodec.decodeDynamicBytes(twoWordPayload.dropLast(64))
        }
    }

    @Test
    fun dynamicBytesRejectsNonZeroPadding() {
        val valid = abiDynamicBytesResult("deadbe")
        val nonZeroPadding = valid.dropLast(2) + "01"

        assertFailsWith<IllegalArgumentException> {
            EthereumAbiCodec.decodeDynamicBytes(nonZeroPadding)
        }
    }

    @Test
    fun dynamicBytesRejectsDataAfterThePaddedPayload() {
        val valid = abiDynamicBytesResult("deadbe")

        assertFailsWith<IllegalArgumentException> {
            EthereumAbiCodec.decodeDynamicBytes(valid + "00".repeat(32))
        }
    }

    @Test
    fun dynamicBytesPayloadLimitIsInclusive() {
        val result = abiDynamicBytesResult("deadbe")

        assertContentEquals(
            "deadbe".codecHexToByteArray(),
            EthereumAbiCodec.decodeDynamicBytes(result, maxPayloadBytes = 3),
        )
        assertFailsWith<IllegalArgumentException> {
            EthereumAbiCodec.decodeDynamicBytes(result, maxPayloadBytes = 2)
        }
    }

    @Test
    fun deployedFixturePinsTheExactPayloadLimitBoundary() {
        val result = abiDynamicBytesResult(DEPLOYED_ANVIL_CODEC_CBOR_HEX)

        assertContentEquals(
            DEPLOYED_ANVIL_CODEC_CBOR_HEX.codecHexToByteArray(),
            EthereumAbiCodec.decodeDynamicBytes(result, maxPayloadBytes = 183),
        )
        assertFailsWith<IllegalArgumentException> {
            EthereumAbiCodec.decodeDynamicBytes(result, maxPayloadBytes = 182)
        }
    }

    @Test
    fun dynamicBytesRequiresTheLiteralLowercaseJsonRpcPrefix() {
        val valid = abiDynamicBytesResult("deadbe")

        assertFailsWith<IllegalArgumentException> {
            EthereumAbiCodec.decodeDynamicBytes(valid.removePrefix("0x"))
        }
        assertFailsWith<IllegalArgumentException> {
            EthereumAbiCodec.decodeDynamicBytes("0X" + valid.drop(2))
        }
    }

    @Test
    fun dynamicBytesRejectsUnsignedLengthsOutsideTheSupportedIntRange() {
        val offsetWord = abiWord(32)

        assertFailsWith<IllegalArgumentException> {
            EthereumAbiCodec.decodeDynamicBytes(
                "0x$offsetWord${"00".repeat(28)}80000000",
                maxPayloadBytes = Int.MAX_VALUE,
            )
        }
        assertFailsWith<IllegalArgumentException> {
            EthereumAbiCodec.decodeDynamicBytes(
                "0x$offsetWord${"00".repeat(28)}ffffffff",
                maxPayloadBytes = Int.MAX_VALUE,
            )
        }
    }

    @Test
    fun dynamicBytesRejectsMalformedHex() {
        val valid = abiDynamicBytesResult("deadbe")

        assertFailsWith<IllegalArgumentException> {
            EthereumAbiCodec.decodeDynamicBytes(valid.dropLast(1))
        }
        assertFailsWith<IllegalArgumentException> {
            EthereumAbiCodec.decodeDynamicBytes(valid.dropLast(2) + "zz")
        }
    }

    private fun abiDynamicBytesResult(payloadHex: String): String {
        require(payloadHex.length % 2 == 0)
        val payloadBytes = payloadHex.length / 2
        val paddedBytes = ((payloadBytes + 31) / 32) * 32
        return "0x" +
            abiWord(32) +
            abiWord(payloadBytes) +
            payloadHex +
            "00".repeat(paddedBytes - payloadBytes)
    }

    private fun abiWord(value: Int): String = value.toString(16).padStart(64, '0')
}

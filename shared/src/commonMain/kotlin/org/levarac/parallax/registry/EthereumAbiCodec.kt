package org.levarac.parallax.registry

/** Dependency-free ABI codec for EventRegistryClientReader.getEventForClient(bytes32). */
internal object EthereumAbiCodec {
    private const val SELECTOR_HEX: String = "f8cd791d"
    private const val ABI_WORD_BYTES: Int = 32

    internal fun encodeGetEventForClient(eventId: ByteArray): String {
        require(eventId.size == ABI_WORD_BYTES) { "eventId must be exactly 32 bytes" }
        return "0x$SELECTOR_HEX${eventId.toPrefixedHex().removePrefix("0x")}"
    }

    internal fun decodeDynamicBytes(
        resultHex: String,
        maxPayloadBytes: Int = 512 * 1_024,
    ): ByteArray {
        require(maxPayloadBytes >= 0) { "maxPayloadBytes must not be negative" }
        require(resultHex.startsWith("0x")) { "ABI bytes result must use the JSON-RPC 0x prefix" }
        val digits = resultHex.substring(2)
        require(digits.length >= ABI_WORD_BYTES * 4) { "ABI bytes result is truncated" }
        require(digits.length % (ABI_WORD_BYTES * 2) == 0) {
            "ABI bytes result is not word-aligned"
        }
        val maxPaddedPayload = paddedLength(maxPayloadBytes.toLong())
        val maxEncodedBytes = ABI_WORD_BYTES * 2L + maxPaddedPayload
        require(digits.length.toLong() / 2 <= maxEncodedBytes) {
            "ABI bytes result exceeds the configured limit"
        }

        val header = ("0x" + digits.substring(0, ABI_WORD_BYTES * 4)).decodeHex()
        val offset = decodeBoundedWord(header, 0, "offset")
        require(offset == ABI_WORD_BYTES) { "ABI bytes offset must be one word" }
        val length = decodeBoundedWord(header, offset, "length")
        require(length <= maxPayloadBytes) { "ABI bytes payload exceeds the configured limit" }

        val expectedSize = ABI_WORD_BYTES * 2L + paddedLength(length.toLong())
        require(digits.length.toLong() / 2 == expectedSize) {
            "ABI bytes result has truncation or trailing data"
        }
        val encoded = resultHex.decodeHex()

        val payloadStart = ABI_WORD_BYTES * 2
        for (index in payloadStart + length until expectedSize.toInt()) {
            require(encoded[index] == 0.toByte()) { "ABI bytes padding must be zero" }
        }
        return encoded.copyOfRange(payloadStart, payloadStart + length)
    }

    private fun paddedLength(length: Long): Long =
        if (length == 0L) 0L else ((length - 1L) / ABI_WORD_BYTES + 1L) * ABI_WORD_BYTES

    private fun decodeBoundedWord(bytes: ByteArray, offset: Int, label: String): Int {
        require(offset >= 0 && offset + ABI_WORD_BYTES <= bytes.size) { "ABI $label word is truncated" }
        for (index in offset until offset + ABI_WORD_BYTES - Int.SIZE_BYTES) {
            require(bytes[index] == 0.toByte()) { "ABI $label exceeds the supported size" }
        }
        var value = 0L
        for (index in offset + ABI_WORD_BYTES - Int.SIZE_BYTES until offset + ABI_WORD_BYTES) {
            value = (value shl 8) or (bytes[index].toLong() and 0xff)
        }
        require(value <= Int.MAX_VALUE) { "ABI $label exceeds the supported size" }
        return value.toInt()
    }
}

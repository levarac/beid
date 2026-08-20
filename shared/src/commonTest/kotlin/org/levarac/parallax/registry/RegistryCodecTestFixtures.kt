package org.levarac.parallax.registry

internal const val DEPLOYED_ANVIL_CODEC_CBOR_HEX =
    "a3010102a40154f39fd6e51aad88f6f4ce6ab8827279cfffb922660254709979" +
        "70c51812dc3a010c7d01b50e0d17dc79c8035820000000000000000000000000" +
        "0000000000000000000000000000000000005678041a6a86ae6803a301010201" +
        "0381860158200000000000000000000000000000000000000000000000000000" +
        "0000000000005820000000000000000000000000000000000000000000000000" +
        "00000000000000d11a773594001a773594641a6a86ae75"

internal val CODEC_ZERO_DIGEST_HEX: String = "00".repeat(32)

internal data class CodecDefinitionFixture(
    val sequence: Long,
    val previousDefinitionDigestHex: String,
    val definitionDigestHex: String,
    val validFrom: Long,
    val validUntil: Long,
    val anchoredAt: Long,
)

internal fun codecRegistryContextFixture(
    records: List<CodecDefinitionFixture>,
    definitionState: Int = if (records.isEmpty()) 0 else 1,
    latestSequence: Long = records.lastOrNull()?.sequence ?: 0L,
    schemaVersion: Int = 1,
    registeredAt: Long = 1_787_211_368L,
): ByteArray = CanonicalCodecCborFixtureBuilder().apply {
    map(3)
    unsigned(1)
    unsigned(schemaVersion.toLong())

    unsigned(2)
    map(4)
    unsigned(1)
    bytes("f39fd6e51aad88f6f4ce6ab8827279cfffb92266")
    unsigned(2)
    bytes("70997970c51812dc3a010c7d01b50e0d17dc79c8")
    unsigned(3)
    bytes("00".repeat(30) + "5678")
    unsigned(4)
    unsigned(registeredAt)

    unsigned(3)
    map(3)
    unsigned(1)
    unsigned(definitionState.toLong())
    unsigned(2)
    unsigned(latestSequence)
    unsigned(3)
    array(records.size)
    records.forEach { record ->
        array(6)
        unsigned(record.sequence)
        bytes(record.previousDefinitionDigestHex)
        bytes(record.definitionDigestHex)
        unsigned(record.validFrom)
        unsigned(record.validUntil)
        unsigned(record.anchoredAt)
    }
}.toByteArray()

internal fun String.codecHexToByteArray(): ByteArray {
    require(length % 2 == 0) { "hex must contain complete bytes" }
    return ByteArray(length / 2) { index ->
        val offset = index * 2
        ((this[offset].codecHexNibble() shl 4) or this[offset + 1].codecHexNibble()).toByte()
    }
}

private fun Char.codecHexNibble(): Int = when (this) {
    in '0'..'9' -> this - '0'
    in 'a'..'f' -> this - 'a' + 10
    in 'A'..'F' -> this - 'A' + 10
    else -> error("invalid hex character: $this")
}

private class CanonicalCodecCborFixtureBuilder {
    private val output = mutableListOf<Byte>()

    fun unsigned(value: Long) = typeAndValue(majorType = 0, value = value)

    fun bytes(hex: String) {
        val value = hex.codecHexToByteArray()
        typeAndValue(majorType = 2, value = value.size.toLong())
        value.forEach(output::add)
    }

    fun array(size: Int) = typeAndValue(majorType = 4, value = size.toLong())

    fun map(size: Int) = typeAndValue(majorType = 5, value = size.toLong())

    fun toByteArray(): ByteArray = output.toByteArray()

    private fun typeAndValue(majorType: Int, value: Long) {
        require(value >= 0L)
        when {
            value < 24L -> byte((majorType shl 5) or value.toInt())
            value <= 0xffL -> {
                byte((majorType shl 5) or 24)
                byte(value.toInt())
            }
            value <= 0xffffL -> {
                byte((majorType shl 5) or 25)
                byte((value ushr 8).toInt())
                byte(value.toInt())
            }
            value <= 0xffff_ffffL -> {
                byte((majorType shl 5) or 26)
                byte((value ushr 24).toInt())
                byte((value ushr 16).toInt())
                byte((value ushr 8).toInt())
                byte(value.toInt())
            }
            else -> {
                byte((majorType shl 5) or 27)
                for (shift in 56 downTo 0 step 8) {
                    byte((value ushr shift).toInt())
                }
            }
        }
    }

    private fun byte(value: Int) {
        output += (value and 0xff).toByte()
    }
}

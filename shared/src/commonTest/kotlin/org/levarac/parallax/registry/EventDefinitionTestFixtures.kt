package org.levarac.parallax.registry

internal val DEFINITION_EVENT_ID_HEX: String = "01".repeat(32)
internal val DEFINITION_AUTHORITY_KEY_HEX: String = "02".repeat(32)
internal val DEFINITION_SUBJECT_KEY_HEX: String = "03".repeat(32)
internal val DEFINITION_ISSUER_KEY_HEX: String = "04".repeat(32)
internal val DEFINITION_SIGNATURE_HEX: String = "05".repeat(64)

internal data class DelegationFixture(
    val subjectKeyIdHex: String = DEFINITION_SUBJECT_KEY_HEX,
    val roleBits: Long = DelegationRoles.RECEPTION,
    val issuedAt: Long = 120L,
    val validFrom: Long = 130L,
    val validUntil: Long = 180L,
    val issuerKeyIdHex: String = DEFINITION_ISSUER_KEY_HEX,
    val signatureHex: String = DEFINITION_SIGNATURE_HEX,
)

internal fun eventDefinitionCbor(
    eventIdHex: String = DEFINITION_EVENT_ID_HEX,
    validFrom: Long = 100L,
    validUntil: Long = 200L,
    signedAt: Long = 90L,
    authorityKeyIdHex: String = DEFINITION_AUTHORITY_KEY_HEX,
    authoritySignatureHex: String = DEFINITION_SIGNATURE_HEX,
    delegations: List<DelegationFixture> = listOf(DelegationFixture()),
    schemaVersion: Long = 1L,
): ByteArray = DefinitionCborFixtureBuilder().apply {
    map(8)
    unsigned(1)
    unsigned(schemaVersion)
    unsigned(2)
    bytes(eventIdHex)
    unsigned(3)
    unsigned(validFrom)
    unsigned(4)
    unsigned(validUntil)
    unsigned(5)
    unsigned(signedAt)
    unsigned(6)
    bytes(authorityKeyIdHex)
    unsigned(7)
    bytes(authoritySignatureHex)
    unsigned(8)
    array(delegations.size)
    delegations.forEach { delegation ->
        map(9)
        unsigned(1)
        unsigned(1L)
        unsigned(2)
        bytes(eventIdHex)
        unsigned(3)
        bytes(delegation.subjectKeyIdHex)
        unsigned(4)
        unsigned(delegation.roleBits)
        unsigned(5)
        unsigned(delegation.issuedAt)
        unsigned(6)
        unsigned(delegation.validFrom)
        unsigned(7)
        unsigned(delegation.validUntil)
        unsigned(8)
        bytes(delegation.issuerKeyIdHex)
        unsigned(9)
        bytes(delegation.signatureHex)
    }
}.toByteArray()

internal fun definitionRecordFor(
    payload: ByteArray,
    eventIdHex: String = DEFINITION_EVENT_ID_HEX,
    validFrom: Long = 100L,
    validUntil: Long = 200L,
): RegistryDefinitionRecord = RegistryDefinitionRecord(
    sequence = 1L,
    previousDefinitionDigestHex = "0x" + "00".repeat(32),
    definitionDigestHex = Sha256.digest(payload).toPrefixedHex(),
    validFrom = validFrom,
    validUntil = validUntil,
    anchoredAt = validFrom - 1L,
)

internal class DefinitionCborFixtureBuilder {
    private val output = mutableListOf<Byte>()

    fun unsigned(value: Long) = typeAndValue(majorType = 0, value = value)

    fun bytes(hex: String) {
        val value = hex.removePrefix("0x").fixtureHexToByteArray()
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

private fun String.fixtureHexToByteArray(): ByteArray {
    require(length % 2 == 0) { "fixture hex must contain complete bytes" }
    return ByteArray(length / 2) { index ->
        val offset = index * 2
        ((this[offset].fixtureHexNibble() shl 4) or this[offset + 1].fixtureHexNibble()).toByte()
    }
}

private fun Char.fixtureHexNibble(): Int = when (this) {
    in '0'..'9' -> this - '0'
    in 'a'..'f' -> this - 'a' + 10
    in 'A'..'F' -> this - 'A' + 10
    else -> error("invalid fixture hex character: $this")
}

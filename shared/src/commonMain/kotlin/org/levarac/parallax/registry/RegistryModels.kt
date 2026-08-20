package org.levarac.parallax.registry

/** Immutable registration facts owned by EventRegistry. */
public class RegistryRegistration internal constructor(
    public val registrarHex: String,
    public val operatorHex: String,
    public val keySetDigestHex: String,
    public val registeredAt: Long,
)

/** One immutable EventDefinitionRegistry anchor, without the off-chain definition bytes. */
public class RegistryDefinitionRecord internal constructor(
    public val sequence: Long,
    public val previousDefinitionDigestHex: String,
    public val definitionDigestHex: String,
    public val validFrom: Long,
    public val validUntil: Long,
    public val anchoredAt: Long,
)

/**
 * Canonical client context returned by EventRegistryClientReader CBOR schema v1.
 *
 * Signed Event Definition bytes deliberately do not appear here. A caller obtains those bytes
 * off-chain and verifies their digest and authority keys against these chain-owned facts.
 */
public class RegistryEventContext internal constructor(
    public val schemaVersion: Int,
    public val registration: RegistryRegistration,
    public val definitionState: Int,
    public val latestSequence: Long,
    internal val definitions: List<RegistryDefinitionRecord>,
) {
    public val definitionCount: Int
        get() = definitions.size

    public val latestDefinitionDigestHex: String?
        get() = definitions.lastOrNull()?.definitionDigestHex

    public fun definitionAt(index: Int): RegistryDefinitionRecord? = definitions.getOrNull(index)
}

/** Selects an anchored definition locally at use time; the judgement is never persisted. */
public fun definitionForUseTime(
    context: RegistryEventContext,
    useTimeEpochSeconds: Long,
): RegistryDefinitionRecord? = DefinitionSelection.select(context, useTimeEpochSeconds)

internal fun ByteArray.toPrefixedHex(): String = buildString(2 + size * 2) {
    append("0x")
    for (byte in this@toPrefixedHex) {
        val value = byte.toInt() and 0xff
        append(HEX_DIGITS[value ushr 4])
        append(HEX_DIGITS[value and 0x0f])
    }
}

internal fun String.decodeHex(expectedBytes: Int? = null): ByteArray {
    val digits = if (startsWith("0x") || startsWith("0X")) substring(2) else this
    require(digits.length % 2 == 0) { "hex value must contain complete bytes" }
    if (expectedBytes != null) {
        require(digits.length == expectedBytes * 2) { "hex value must be exactly $expectedBytes bytes" }
    }
    return ByteArray(digits.length / 2) { index ->
        val high = digits[index * 2].digitToIntOrNull(16)
            ?: throw IllegalArgumentException("hex value contains a non-hex character")
        val low = digits[index * 2 + 1].digitToIntOrNull(16)
            ?: throw IllegalArgumentException("hex value contains a non-hex character")
        ((high shl 4) or low).toByte()
    }
}

private const val HEX_DIGITS: String = "0123456789abcdef"

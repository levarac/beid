package org.levarac.parallax.registry

/** Strict decoder for the deterministic integer-key CBOR emitted by EventRegistryClientReader. */
internal object RegistryCborCodec {
    private const val MAX_CBOR_BYTES: Int = 512 * 1_024
    private const val SCHEMA_VERSION: Long = 1
    private const val NO_DEFINITIONS: Long = 0
    private const val HAS_DEFINITIONS: Long = 1

    internal fun decode(bytes: ByteArray): RegistryEventContext {
        require(bytes.size <= MAX_CBOR_BYTES) { "registry CBOR exceeds the configured limit" }
        val reader = CanonicalCborReader(bytes)

        reader.expectMap(3)
        reader.expectUnsigned(1)
        val schemaVersion = reader.readUnsigned()
        require(schemaVersion == SCHEMA_VERSION) { "unsupported registry CBOR schema version" }

        reader.expectUnsigned(2)
        val registration = decodeRegistration(reader)

        reader.expectUnsigned(3)
        val definitionMeta = decodeDefinitionMeta(reader, registration.registeredAt)
        reader.requireFinished()

        return RegistryEventContext(
            schemaVersion = schemaVersion.toInt(),
            registration = registration,
            definitionState = definitionMeta.state.toInt(),
            latestSequence = definitionMeta.latestSequence,
            definitions = definitionMeta.definitions,
        )
    }

    private fun decodeRegistration(reader: CanonicalCborReader): RegistryRegistration {
        reader.expectMap(4)
        reader.expectUnsigned(1)
        val registrar = reader.readByteString(20)
        reader.expectUnsigned(2)
        val operator = reader.readByteString(20)
        reader.expectUnsigned(3)
        val keySetDigest = reader.readByteString(32)
        reader.expectUnsigned(4)
        val registeredAt = reader.readUnsigned()

        require(registrar.any { it != 0.toByte() }) { "registrar must not be zero" }
        require(operator.any { it != 0.toByte() }) { "operator must not be zero" }
        require(keySetDigest.any { it != 0.toByte() }) { "keySetDigest must not be zero" }
        return RegistryRegistration(
            registrarHex = registrar.toPrefixedHex(),
            operatorHex = operator.toPrefixedHex(),
            keySetDigestHex = keySetDigest.toPrefixedHex(),
            registeredAt = registeredAt,
        )
    }

    private fun decodeDefinitionMeta(
        reader: CanonicalCborReader,
        registeredAt: Long,
    ): DefinitionMeta {
        reader.expectMap(3)
        reader.expectUnsigned(1)
        val state = reader.readUnsigned()
        require(state == NO_DEFINITIONS || state == HAS_DEFINITIONS) { "invalid definition anchor state" }
        reader.expectUnsigned(2)
        val latestSequence = reader.readUnsigned()
        reader.expectUnsigned(3)
        val count = reader.readArrayLength()
        require(count <= reader.remainingBytes / MIN_DEFINITION_RECORD_BYTES) {
            "definition count exceeds the remaining CBOR payload"
        }
        val definitions = ArrayList<RegistryDefinitionRecord>(count)

        var previousDigest = ZERO_DIGEST_HEX
        var previousValidUntil: Long? = null
        var previousAnchoredAt: Long? = null
        repeat(count) { index ->
            reader.expectArray(6)
            val sequence = reader.readUnsigned()
            val predecessor = reader.readByteString(32).toPrefixedHex()
            val digestBytes = reader.readByteString(32)
            val digest = digestBytes.toPrefixedHex()
            val validFrom = reader.readUnsigned()
            val validUntil = reader.readUnsigned()
            val anchoredAt = reader.readUnsigned()

            val expectedSequence = index.toLong() + 1
            require(sequence == expectedSequence) { "definition sequences must be contiguous and one-based" }
            require(predecessor == previousDigest) { "definition predecessor does not match the prior digest" }
            require(digestBytes.any { it != 0.toByte() }) { "definition digest must not be zero" }
            require(validFrom <= validUntil) { "definition validity window is inverted" }
            require(validFrom <= PROTOCOL_SAFE_UINT_MAX && validUntil <= PROTOCOL_SAFE_UINT_MAX) {
                "definition validity exceeds the protocol safe-integer maximum"
            }
            require(anchoredAt < validFrom) { "definition must be anchored before validity" }
            require(registeredAt <= anchoredAt) { "definition cannot predate event registration" }
            previousValidUntil?.let { priorEnd ->
                require(validFrom > priorEnd) { "definition validity windows must not overlap" }
            }
            previousAnchoredAt?.let { priorAnchor ->
                require(anchoredAt >= priorAnchor) { "definition anchor times must not decrease" }
            }

            definitions += RegistryDefinitionRecord(
                sequence = sequence,
                previousDefinitionDigestHex = predecessor,
                definitionDigestHex = digest,
                validFrom = validFrom,
                validUntil = validUntil,
                anchoredAt = anchoredAt,
            )
            previousDigest = digest
            previousValidUntil = validUntil
            previousAnchoredAt = anchoredAt
        }

        require(latestSequence == count.toLong()) { "latestSequence must equal the returned record count" }
        require((state == HAS_DEFINITIONS) == definitions.isNotEmpty()) {
            "definition anchor state must match the returned records"
        }
        return DefinitionMeta(state, latestSequence, definitions)
    }

    private data class DefinitionMeta(
        val state: Long,
        val latestSequence: Long,
        val definitions: List<RegistryDefinitionRecord>,
    )
}

private class CanonicalCborReader(private val bytes: ByteArray) {
    private var offset: Int = 0

    val remainingBytes: Int
        get() = bytes.size - offset

    fun expectMap(expectedLength: Int) {
        val actual = readLength(expectedMajor = 5)
        require(actual == expectedLength) { "unexpected CBOR map length" }
    }

    fun expectArray(expectedLength: Int) {
        val actual = readLength(expectedMajor = 4)
        require(actual == expectedLength) { "unexpected CBOR array length" }
    }

    fun readArrayLength(): Int = readLength(expectedMajor = 4)

    fun expectUnsigned(expected: Long) {
        require(readUnsigned() == expected) { "unexpected CBOR integer key" }
    }

    fun readUnsigned(): Long {
        val initial = readByte()
        require(initial ushr 5 == 0) { "expected a CBOR unsigned integer" }
        return readAdditional(initial and 0x1f)
    }

    fun readByteString(expectedLength: Int): ByteArray {
        val actualLength = readLength(expectedMajor = 2)
        require(actualLength == expectedLength) { "unexpected CBOR byte-string length" }
        require(actualLength <= bytes.size - offset) { "truncated CBOR byte string" }
        return bytes.copyOfRange(offset, offset + actualLength).also { offset += actualLength }
    }

    fun requireFinished() {
        require(offset == bytes.size) { "trailing bytes after registry CBOR" }
    }

    private fun readLength(expectedMajor: Int): Int {
        val initial = readByte()
        require(initial ushr 5 == expectedMajor) { "unexpected CBOR major type" }
        val length = readAdditional(initial and 0x1f)
        require(length <= Int.MAX_VALUE) { "CBOR container is too large" }
        return length.toInt()
    }

    private fun readAdditional(additional: Int): Long = when {
        additional < 24 -> additional.toLong()
        additional == 24 -> readUnsignedBytes(1).also {
            require(it >= 24) { "non-minimal CBOR integer or length" }
        }
        additional == 25 -> readUnsignedBytes(2).also {
            require(it > 0xff) { "non-minimal CBOR integer or length" }
        }
        additional == 26 -> readUnsignedBytes(4).also {
            require(it > 0xffff) { "non-minimal CBOR integer or length" }
        }
        additional == 27 -> readUnsignedBytes(8).also {
            require(it > 0xffff_ffffL) { "non-minimal CBOR integer or length" }
        }
        else -> throw IllegalArgumentException("indefinite or reserved CBOR encoding is not allowed")
    }

    private fun readUnsignedBytes(count: Int): Long {
        require(count <= bytes.size - offset) { "truncated CBOR integer or length" }
        if (count == 8) {
            require((bytes[offset].toInt() and 0x80) == 0) { "CBOR uint64 exceeds the supported signed range" }
        }
        var value = 0L
        repeat(count) {
            value = (value shl 8) or readByte().toLong()
        }
        return value
    }

    private fun readByte(): Int {
        require(offset < bytes.size) { "truncated registry CBOR" }
        return bytes[offset++].toInt() and 0xff
    }
}

private const val ZERO_DIGEST_HEX: String =
    "0x0000000000000000000000000000000000000000000000000000000000000000"
private const val PROTOCOL_SAFE_UINT_MAX: Long = 9_007_199_254_740_991L
private const val MIN_DEFINITION_RECORD_BYTES: Int = 73

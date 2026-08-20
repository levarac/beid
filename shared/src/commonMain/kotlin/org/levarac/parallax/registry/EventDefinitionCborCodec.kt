package org.levarac.parallax.registry

/**
 * Strict decoder for the minimal integer-key CBOR EventDefinition/v1 schema.
 *
 * EventDefinition/v1 is a map with exactly these keys, in ascending order:
 * 1 schema version, 2 event ID, 3 valid-from, 4 valid-until, 5 signed-at,
 * 6 authority key ID, 7 authority signature, and 8 delegation certificates.
 *
 * DelegationCert/v1 is a map with exactly these keys, in ascending order:
 * 1 schema version, 2 event ID, 3 subject key ID, 4 role bits, 5 issued-at,
 * 6 valid-from, 7 valid-until, 8 issuer key ID, and 9 signature.
 */
internal object EventDefinitionCborCodec {
    private const val MAX_PAYLOAD_BYTES: Int = 512 * 1_024
    private const val EVENT_DEFINITION_SCHEMA_VERSION: Long = 1L
    private const val DELEGATION_CERT_SCHEMA_VERSION: Long = 1L
    private const val MAX_DELEGATIONS: Int = 1_024
    private const val HASH_BYTES: Int = 32
    private const val SIGNATURE_BYTES: Int = 64

    internal fun decode(bytes: ByteArray): EventDefinition = try {
        require(bytes.size <= MAX_PAYLOAD_BYTES) { "signed definition exceeds the configured limit" }
        val reader = DefinitionCborReader(bytes)
        reader.expectMap(8)
        reader.expectUnsigned(1L)
        val version = reader.readUnsigned()
        if (version != EVENT_DEFINITION_SCHEMA_VERSION) {
            throw DefinitionDecodeException(
                DefinitionDecodeError.UNSUPPORTED_VERSION,
                "unsupported EventDefinition schema version",
            )
        }
        reader.expectUnsigned(2L)
        val eventId = reader.readByteString(HASH_BYTES).toPrefixedHex()
        reader.expectUnsigned(3L)
        val validFrom = reader.readProtocolTime("definition validFrom")
        reader.expectUnsigned(4L)
        val validUntil = reader.readProtocolTime("definition validUntil")
        reader.expectUnsigned(5L)
        val signedAt = reader.readProtocolTime("definition signedAt")
        reader.expectUnsigned(6L)
        val authorityKeyId = reader.readByteString(HASH_BYTES).toPrefixedHex()
        reader.expectUnsigned(7L)
        val authoritySignature = reader.readByteString(SIGNATURE_BYTES).toPrefixedHex()
        reader.expectUnsigned(8L)
        val delegationCount = reader.readArrayLength()
        require(delegationCount <= MAX_DELEGATIONS) { "too many delegation certificates" }
        if (validFrom > validUntil || signedAt > validFrom) {
            throw DefinitionDecodeException(
                DefinitionDecodeError.INVALID_VALIDITY,
                "definition validity or signing window is invalid",
            )
        }
        val delegations = ArrayList<DelegationCert>(delegationCount)
        repeat(delegationCount) {
            delegations += decodeDelegation(reader, eventId, signedAt, validFrom, validUntil)
        }
        reader.requireFinished()
        EventDefinition(
            schemaVersion = version.toInt(),
            eventIdHex = eventId,
            validFrom = validFrom,
            validUntil = validUntil,
            signedAt = signedAt,
            authorityKeyIdHex = authorityKeyId,
            authoritySignatureHex = authoritySignature,
            delegations = delegations,
        )
    } catch (error: DefinitionDecodeException) {
        throw error
    } catch (error: IllegalArgumentException) {
        throw DefinitionDecodeException(
            reason = DefinitionDecodeError.MALFORMED,
            message = error.message ?: "malformed EventDefinition CBOR",
            cause = error,
        )
    }

    private fun decodeDelegation(
        reader: DefinitionCborReader,
        eventId: String,
        definitionSignedAt: Long,
        definitionValidFrom: Long,
        definitionValidUntil: Long,
    ): DelegationCert {
        reader.expectMap(9)
        reader.expectUnsigned(1L)
        val version = reader.readUnsigned()
        if (version != DELEGATION_CERT_SCHEMA_VERSION) {
            throw DefinitionDecodeException(
                DefinitionDecodeError.UNSUPPORTED_VERSION,
                "unsupported DelegationCert schema version",
            )
        }
        reader.expectUnsigned(2L)
        val certEventId = reader.readByteString(HASH_BYTES).toPrefixedHex()
        if (certEventId != eventId) {
            throw DefinitionDecodeException(
                DefinitionDecodeError.EVENT_ID_MISMATCH,
                "delegation certificate event ID does not match its definition",
            )
        }
        reader.expectUnsigned(3L)
        val subjectKeyId = reader.readByteString(HASH_BYTES).toPrefixedHex()
        reader.expectUnsigned(4L)
        val roleBits = reader.readUnsigned()
        require(roleBits != 0L && roleBits and DelegationRoles.KNOWN_MASK == roleBits) {
            throw DefinitionDecodeException(
                DefinitionDecodeError.INVALID_ROLE,
                "delegation certificate contains an unknown or empty role",
            )
        }
        reader.expectUnsigned(5L)
        val issuedAt = reader.readProtocolTime("delegation issuedAt")
        reader.expectUnsigned(6L)
        val validFrom = reader.readProtocolTime("delegation validFrom")
        reader.expectUnsigned(7L)
        val validUntil = reader.readProtocolTime("delegation validUntil")
        reader.expectUnsigned(8L)
        val issuerKeyId = reader.readByteString(HASH_BYTES).toPrefixedHex()
        reader.expectUnsigned(9L)
        val signature = reader.readByteString(SIGNATURE_BYTES).toPrefixedHex()

        if (validFrom > validUntil || issuedAt > validFrom ||
            validFrom < definitionValidFrom || validUntil > definitionValidUntil
        ) {
            throw DefinitionDecodeException(
                DefinitionDecodeError.FORWARD_VALIDITY,
                "delegation certificate validity is outside the definition window",
            )
        }
        if (issuedAt < definitionSignedAt) {
            throw DefinitionDecodeException(
                DefinitionDecodeError.FORWARD_VALIDITY,
                "delegation certificate is issued before its definition",
            )
        }
        return DelegationCert(
            schemaVersion = version.toInt(),
            eventIdHex = certEventId,
            subjectKeyIdHex = subjectKeyId,
            roleBits = roleBits,
            issuedAt = issuedAt,
            validFrom = validFrom,
            validUntil = validUntil,
            issuerKeyIdHex = issuerKeyId,
            signatureHex = signature,
        )
    }
}

private class DefinitionCborReader(private val bytes: ByteArray) {
    private var offset: Int = 0

    fun expectMap(expectedLength: Int) {
        val actual = readLength(expectedMajor = 5)
        require(actual == expectedLength) { "unexpected EventDefinition map length" }
    }

    fun expectUnsigned(expected: Long) {
        require(readUnsigned() == expected) { "unexpected EventDefinition integer key" }
    }

    fun expectArray(expectedLength: Int) {
        val actual = readLength(expectedMajor = 4)
        require(actual == expectedLength) { "unexpected DelegationCert array length" }
    }

    fun readArrayLength(): Int = readLength(expectedMajor = 4)

    fun readUnsigned(): Long {
        val initial = readByte()
        require(initial ushr 5 == 0) { "expected a CBOR unsigned integer" }
        return readAdditional(initial and 0x1f)
    }

    fun readProtocolTime(label: String): Long {
        val value = readUnsigned()
        require(value <= PROTOCOL_SAFE_UINT_MAX) { "$label exceeds the protocol safe-integer maximum" }
        return value
    }

    fun readByteString(expectedLength: Int): ByteArray {
        val actualLength = readLength(expectedMajor = 2)
        require(actualLength == expectedLength) { "unexpected signed definition byte-string length" }
        require(actualLength <= bytes.size - offset) { "truncated signed definition byte string" }
        return bytes.copyOfRange(offset, offset + actualLength).also { offset += actualLength }
    }

    fun requireFinished() {
        require(offset == bytes.size) { "trailing bytes after signed EventDefinition" }
    }

    private fun readLength(expectedMajor: Int): Int {
        val initial = readByte()
        require(initial ushr 5 == expectedMajor) { "unexpected signed definition CBOR major type" }
        val length = readAdditional(initial and 0x1f)
        require(length <= Int.MAX_VALUE) { "signed definition container is too large" }
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
            require((bytes[offset].toInt() and 0x80) == 0) {
                "CBOR uint64 exceeds the supported signed range"
            }
        }
        var value = 0L
        repeat(count) {
            value = (value shl 8) or readByte().toLong()
        }
        return value
    }

    private fun readByte(): Int {
        require(offset < bytes.size) { "truncated signed EventDefinition CBOR" }
        return bytes[offset++].toInt() and 0xff
    }
}

private const val PROTOCOL_SAFE_UINT_MAX: Long = 9_007_199_254_740_991L

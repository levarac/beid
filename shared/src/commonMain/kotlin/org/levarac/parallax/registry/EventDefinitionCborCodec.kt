package org.levarac.parallax.registry

import org.levarac.parallax.observation.CanonicalCbor
import org.levarac.parallax.observation.CompactEs256kSignature
import org.levarac.parallax.observation.CompressedSecp256k1PublicKey
import org.levarac.parallax.observation.ByteString32
import org.levarac.parallax.observation.ProtocolUInt
import org.levarac.parallax.observation.Secp256k1

/**
 * Decoder and verifier for Parallax's canonical Event Definition protocol.
 *
 * This is deliberately a small strict reader rather than a generic CBOR model. The wire
 * contract requires definite lengths, minimal integer encodings, exact integer-key maps, and no
 * trailing bytes. Every signature and digest is checked before a context crosses the native
 * boundary.
 */
internal object EventDefinitionCborCodec {
    private const val EVENT_DEFINITION_VERSION: Long = 1L
    private const val EVENT_KEY_SET_VERSION: Long = 1L
    private const val COSE_SIGN1_TAG: Long = 18L
    private const val COSE_ALGORITHM_ES256K: Long = -47L
    private const val COSE_SIGNATURE_CONTEXT: String = "Signature1"
    private const val EVENT_DEFINITION_MEDIA_TYPE: String =
        "application/vnd.levarac.event-definition+cbor"
    private const val EVENT_ID_DOMAIN: String = "levarac:event:v1"
    private const val COSE_KID_DOMAIN: String = "levarac:cose-kid:v1\u0000"
    private const val KEY_SET_DIGEST_DOMAIN: String = "levarac:event-key-set-digest:v1\u0000"
    private const val DEFINITION_DIGEST_DOMAIN: String = "levarac:event-definition-digest:v1\u0000"
    private const val OPERATOR_ID_DOMAIN: String = "levarac:operator-id:v1\u0000"
    private const val HASH_BYTES: Int = 32
    private const val ADDRESS_BYTES: Int = 20
    private const val PUBLIC_KEY_BYTES: Int = 33
    private const val SIGNATURE_BYTES: Int = 64
    private const val KID_BYTES: Int = 8
    private const val EVENT_CODE_HASH_BYTES: Int = 8
    private const val MAX_AUTHORITY_KEYS: Int = 1_024
    private val ZERO_DIGEST = ByteArray(HASH_BYTES)

    internal class VerifiedDefinition(
        val definition: EventDefinition,
        val keySet: EventKeySet,
        val digest: ByteArray,
    )

    internal fun verify(
        signedBytes: ByteArray,
        encodedKeySet: ByteArray,
        eventId: ByteArray,
        registration: RegistryRegistration,
        record: RegistryDefinitionRecord,
        at: Long,
    ): VerifiedDefinition = try {
        require(signedBytes.size <= MAX_EVENT_DEFINITION_PAYLOAD_BYTES) {
            "signed definition exceeds the configured limit"
        }
        require(eventId.size == HASH_BYTES) { "event ID must be 32 bytes" }
        val parsed = decodeSignedDefinition(signedBytes)
        val keySet = try {
            decodeEventKeySet(encodedKeySet)
        } catch (error: DefinitionDecodeException) {
            throw error
        } catch (error: Throwable) {
            throw DefinitionDecodeException(
                DefinitionDecodeError.INVALID_KEY_SET,
                error.message ?: "invalid EventKeySet artifact",
                error,
            )
        }
        val keySetDigest = eventKeySetDigest(encodedKeySet)
        if (!parsed.definition.keySetDigest.contentEquals(keySetDigest)) {
            fail(
                DefinitionDecodeError.KEY_SET_DIGEST_MISMATCH,
                "Event Definition keySetDigest does not match the EventKeySet artifact",
            )
        }
        if (!parsed.definition.keySetDigest.contentEquals(registration.keySetDigestHex.decodeHex(HASH_BYTES))) {
            fail(
                DefinitionDecodeError.ANCHOR_MISMATCH,
                "Event Definition keySetDigest does not match the registry registration",
            )
        }
        val authorityKey = verifyAuthoritySignature(parsed, keySet)
        val digest = eventDefinitionDigest(signedBytes)
        requireAnchors(
            definition = parsed.definition,
            signedDigest = digest,
            eventId = eventId,
            registration = registration,
            record = record,
        )
        if (at < parsed.definition.validFrom.value || at > parsed.definition.validUntil.value) {
            fail(
                DefinitionDecodeError.INVALID_VALIDITY,
                "time is outside the Event Definition validity window",
            )
        }
        VerifiedDefinition(
            definition = parsed.definition.toPublic(authorityKey),
            keySet = keySet,
            digest = digest,
        )
    } catch (error: DefinitionDecodeException) {
        throw error
    } catch (error: Throwable) {
        throw DefinitionDecodeException(
            reason = DefinitionDecodeError.MALFORMED,
            message = error.message ?: "malformed canonical Event Definition",
            cause = error,
        )
    }

    internal fun eventDefinitionDigest(signedBytes: ByteArray): ByteArray =
        Sha256.digest(DEFINITION_DIGEST_DOMAIN.encodeToByteArray() + signedBytes)

    internal fun eventKeySetDigest(encodedKeySet: ByteArray): ByteArray {
        val keySet = try {
            decodeEventKeySet(encodedKeySet)
        } catch (error: DefinitionDecodeException) {
            throw error
        } catch (error: Throwable) {
            throw DefinitionDecodeException(
                DefinitionDecodeError.INVALID_KEY_SET,
                error.message ?: "invalid EventKeySet",
                error,
            )
        }
        // Keep the validation result live so this function cannot be called as a hash-only escape
        // hatch for malformed key-set bytes.
        require(keySet.threshold == 1)
        return Sha256.digest(KEY_SET_DIGEST_DOMAIN.encodeToByteArray() + encodedKeySet)
    }

    private fun decodeSignedDefinition(bytes: ByteArray): ParsedSignedDefinition {
        val reader = StrictCborReader(bytes)
        reader.expectTag(COSE_SIGN1_TAG)
        reader.expectArray(4)
        val protectedBytes = reader.readByteString()
        reader.expectMap(0)
        val payloadBytes = reader.readByteString()
        val signature = reader.readByteString(SIGNATURE_BYTES)
        reader.requireFinished()

        val protectedHeaders = decodeProtectedHeaders(protectedBytes)
        val definition = decodeDefinitionPayload(payloadBytes)
        return ParsedSignedDefinition(
            protectedBytes = protectedBytes,
            payloadBytes = payloadBytes,
            signature = signature,
            protectedHeaders = protectedHeaders,
            definition = definition,
        )
    }

    private fun decodeProtectedHeaders(bytes: ByteArray): ProtectedHeaders {
        val reader = StrictCborReader(bytes)
        reader.expectMap(3)
        reader.expectUnsignedKey(1L)
        val algorithm = reader.readNegative()
        reader.expectUnsignedKey(3L)
        val contentType = reader.readText(maxUtf8Bytes = 256)
        reader.expectUnsignedKey(4L)
        val kid = reader.readByteString(KID_BYTES)
        reader.requireFinished()
        if (algorithm != COSE_ALGORITHM_ES256K) {
            fail(DefinitionDecodeError.INVALID_COSE, "COSE algorithm must be ES256K")
        }
        if (contentType != EVENT_DEFINITION_MEDIA_TYPE) {
            fail(DefinitionDecodeError.INVALID_COSE, "unexpected Event Definition payload media type")
        }
        return ProtectedHeaders(kid = kid)
    }

    private fun decodeEventKeySet(bytes: ByteArray): EventKeySet {
        val reader = StrictCborReader(bytes)
        reader.expectMap(3)
        reader.expectUnsignedKey(1L)
        val version = reader.readUnsigned()
        if (version != EVENT_KEY_SET_VERSION) {
            fail(DefinitionDecodeError.UNSUPPORTED_VERSION, "unsupported EventKeySet version")
        }
        reader.expectUnsignedKey(2L)
        val count = reader.readArrayLength()
        if (count !in 1..MAX_AUTHORITY_KEYS) {
            fail(DefinitionDecodeError.INVALID_KEY_SET, "EventKeySet authority key count is invalid")
        }
        val authorityKeys = ArrayList<CompressedSecp256k1PublicKey>(count)
        repeat(count) {
            val bytesForKey = reader.readByteString(PUBLIC_KEY_BYTES)
            if (!Secp256k1.isValidCompressedPublicKey(bytesForKey)) {
                fail(DefinitionDecodeError.INVALID_KEY_SET, "EventKeySet contains an invalid secp256k1 key")
            }
            if (authorityKeys.isNotEmpty() && compareLexicographically(
                    authorityKeys.last().toByteArray(),
                    bytesForKey,
                ) >= 0
            ) {
                fail(DefinitionDecodeError.INVALID_KEY_SET, "EventKeySet keys must be sorted and unique")
            }
            authorityKeys += CompressedSecp256k1PublicKey(bytesForKey)
        }
        reader.expectUnsignedKey(3L)
        val threshold = reader.readUnsigned()
        if (threshold != 1L) {
            fail(DefinitionDecodeError.INVALID_KEY_SET, "EventKeySet v1 threshold must be one")
        }
        reader.requireFinished()
        return EventKeySet(
            version = version.toInt(),
            authorityKeys = authorityKeys,
            threshold = threshold.toInt(),
        )
    }

    private fun decodeDefinitionPayload(bytes: ByteArray): RawDefinition {
        val reader = StrictCborReader(bytes)
        val fieldCount = reader.readMapLength()
        require(fieldCount in 13..15) {
            "Event Definition must contain 13 legacy, 14 gated, or 15 open fields"
        }
        reader.expectUnsignedKey(1L)
        val version = reader.readUnsigned()
        if (version != EVENT_DEFINITION_VERSION) {
            fail(DefinitionDecodeError.UNSUPPORTED_VERSION, "unsupported EventDefinition version")
        }
        reader.expectUnsignedKey(2L)
        val eventId = reader.readByteString(HASH_BYTES)
        reader.expectUnsignedKey(3L)
        val registrar = reader.readByteString(ADDRESS_BYTES)
        reader.expectUnsignedKey(4L)
        val anchorOperator = reader.readByteString(ADDRESS_BYTES)
        reader.expectUnsignedKey(5L)
        val nonce = reader.readByteString(HASH_BYTES)
        reader.expectUnsignedKey(6L)
        val keySetDigest = reader.readByteString(HASH_BYTES)
        reader.expectUnsignedKey(7L)
        val sequence = reader.readProtocolUInt("sequence")
        reader.expectUnsignedKey(8L)
        val previousDefinitionDigest = reader.readByteString(HASH_BYTES)
        reader.expectUnsignedKey(9L)
        val receiptPublicKeyBytes = reader.readByteString(PUBLIC_KEY_BYTES)
        if (!Secp256k1.isValidCompressedPublicKey(receiptPublicKeyBytes)) {
            fail(DefinitionDecodeError.MALFORMED, "receiptPublicKey is not a valid compressed secp256k1 key")
        }
        reader.expectUnsignedKey(10L)
        val operatorId = reader.readByteString(HASH_BYTES)
        reader.expectUnsignedKey(11L)
        val submissionEndpoint = reader.readText(maxUtf8Bytes = 2_048)
        validateSubmissionEndpoint(submissionEndpoint)
        reader.expectUnsignedKey(12L)
        val validFrom = reader.readProtocolUInt("validFrom")
        reader.expectUnsignedKey(13L)
        val validUntil = reader.readProtocolUInt("validUntil")
        val joinMode = if (fieldCount >= 14) {
            reader.expectUnsignedKey(14L)
            when (reader.readUnsigned()) {
                0L -> EventJoinMode.OPEN
                1L -> EventJoinMode.GATED
                else -> fail(DefinitionDecodeError.MALFORMED, "Event Definition joinMode is unknown")
            }
        } else {
            null
        }
        val eventCodeHash = if (fieldCount == 15) {
            reader.expectUnsignedKey(15L)
            reader.readByteString(EVENT_CODE_HASH_BYTES)
        } else {
            null
        }
        reader.requireFinished()

        when (joinMode) {
            EventJoinMode.OPEN -> {
                if (eventCodeHash == null) {
                    fail(DefinitionDecodeError.MALFORMED, "open Event Definition requires eventCodeHash")
                }
                if (!eventCodeHash.contentEquals(eventCodeHashForOpenEventV1(eventId))) {
                    fail(DefinitionDecodeError.MALFORMED, "open Event Definition eventCodeHash is not canonical")
                }
            }
            EventJoinMode.GATED -> if (eventCodeHash != null) {
                fail(DefinitionDecodeError.MALFORMED, "gated Event Definition forbids eventCodeHash")
            }
            null -> Unit
        }

        if (sequence.value < 1L) {
            fail(DefinitionDecodeError.INVALID_VALIDITY, "Event Definition sequence must start at one")
        }
        val previousIsZero = previousDefinitionDigest.contentEquals(ZERO_DIGEST)
        if ((sequence.value == 1L && !previousIsZero) || (sequence.value > 1L && previousIsZero)) {
            fail(DefinitionDecodeError.INVALID_VALIDITY, "Event Definition previous digest does not match sequence")
        }
        if (validUntil.value < validFrom.value) {
            fail(DefinitionDecodeError.INVALID_VALIDITY, "Event Definition validity window is inverted")
        }
        val expectedOperatorId = Sha256.digest(OPERATOR_ID_DOMAIN.encodeToByteArray() + receiptPublicKeyBytes)
        if (!operatorId.contentEquals(expectedOperatorId)) {
            fail(DefinitionDecodeError.OPERATOR_ID_MISMATCH, "operatorId does not match receiptPublicKey")
        }
        val expectedEventId = computeEventId(registrar, anchorOperator, nonce, keySetDigest)
        if (!eventId.contentEquals(expectedEventId)) {
            fail(DefinitionDecodeError.EVENT_ID_MISMATCH, "eventId does not match the Event Definition preimage")
        }
        return RawDefinition(
            version = version.toInt(),
            eventId = eventId,
            registrar = registrar,
            anchorOperator = anchorOperator,
            nonce = nonce,
            keySetDigest = keySetDigest,
            sequence = sequence,
            previousDefinitionDigest = previousDefinitionDigest,
            receiptPublicKey = CompressedSecp256k1PublicKey(receiptPublicKeyBytes),
            operatorId = ByteString32(operatorId),
            submissionEndpoint = submissionEndpoint,
            validFrom = validFrom,
            validUntil = validUntil,
            joinMode = joinMode,
            eventCodeHash = eventCodeHash,
        )
    }

    private fun verifyAuthoritySignature(
        parsed: ParsedSignedDefinition,
        keySet: EventKeySet,
    ): CompressedSecp256k1PublicKey {
        val expectedSignatureDigest = Sha256.digest(
            CanonicalCbor.encode(
                CanonicalCbor.array(
                    CanonicalCbor.text(COSE_SIGNATURE_CONTEXT),
                    CanonicalCbor.bytes(parsed.protectedBytes),
                    CanonicalCbor.bytes(ByteArray(0)),
                    CanonicalCbor.bytes(parsed.payloadBytes),
                ),
            ),
        )
        val signature = CompactEs256kSignature(
            parsed.signature.copyOfRange(0, HASH_BYTES),
            parsed.signature.copyOfRange(HASH_BYTES, SIGNATURE_BYTES),
        )
        for (candidate in keySet.authorityKeys) {
            val expectedKid = Sha256.digest(
                COSE_KID_DOMAIN.encodeToByteArray() + candidate.toByteArray(),
            ).copyOfRange(0, KID_BYTES)
            if (parsed.protectedHeaders.kid.contentEquals(expectedKid) &&
                Secp256k1.verify(
                    digest = expectedSignatureDigest,
                    signature = signature,
                    publicKey = candidate.toByteArray(),
                )
            ) {
                return candidate
            }
        }
        fail(DefinitionDecodeError.INVALID_SIGNATURE, "Event Definition authority signature is invalid")
    }

    private fun requireAnchors(
        definition: RawDefinition,
        signedDigest: ByteArray,
        eventId: ByteArray,
        registration: RegistryRegistration,
        record: RegistryDefinitionRecord,
    ) {
        if (!definition.eventId.contentEquals(eventId)) {
            fail(DefinitionDecodeError.EVENT_ID_MISMATCH, "definition eventId does not match the registry read")
        }
        val registrationRegistrar = registration.registrarHex.decodeHex(ADDRESS_BYTES)
        val registrationOperator = registration.operatorHex.decodeHex(ADDRESS_BYTES)
        if (!definition.registrar.contentEquals(registrationRegistrar) ||
            !definition.anchorOperator.contentEquals(registrationOperator)
        ) {
            fail(DefinitionDecodeError.ANCHOR_MISMATCH, "definition registrar or operator does not match registration")
        }
        if (definition.sequence.value != record.sequence ||
            !definition.previousDefinitionDigest.contentEquals(
                record.previousDefinitionDigestHex.decodeHex(HASH_BYTES),
            ) ||
            !signedDigest.contentEquals(record.definitionDigestHex.decodeHex(HASH_BYTES)) ||
            definition.validFrom.value != record.validFrom ||
            definition.validUntil.value != record.validUntil
        ) {
            fail(DefinitionDecodeError.ANCHOR_MISMATCH, "definition does not match the anchored registry record")
        }
        if (record.anchoredAt < registration.registeredAt) {
            fail(DefinitionDecodeError.ANCHOR_MISMATCH, "definition anchor predates event registration")
        }
        if (record.anchoredAt >= definition.validFrom.value) {
            fail(DefinitionDecodeError.INVALID_VALIDITY, "definition anchor must be earlier than validFrom")
        }
    }

    private fun computeEventId(
        registrar: ByteArray,
        anchorOperator: ByteArray,
        nonce: ByteArray,
        keySetDigest: ByteArray,
    ): ByteArray {
        val eventDomain = Keccak256.digest(EVENT_ID_DOMAIN.encodeToByteArray())
        val registrarWord = ByteArray(12) + registrar
        val operatorWord = ByteArray(12) + anchorOperator
        return Keccak256.digest(eventDomain + registrarWord + operatorWord + nonce + keySetDigest)
    }

    private fun validateSubmissionEndpoint(value: String) {
        val utf8Length = value.encodeToByteArray().size
        if (utf8Length == 0 || utf8Length > 2_048) {
            fail(DefinitionDecodeError.INVALID_ENDPOINT, "submissionEndpoint must be 1..2048 UTF-8 bytes")
        }
        val schemeSeparator = value.indexOf("://")
        val schemeIsHttps = schemeSeparator == 5 && (0 until 5).all { index ->
            val code = value[index].code
            val foldedCode = if (code in 'A'.code..'Z'.code) code + ('a'.code - 'A'.code) else code
            code <= 0x7F && foldedCode == "https"[index].code
        }
        if (!schemeIsHttps) {
            fail(DefinitionDecodeError.INVALID_ENDPOINT, "submissionEndpoint must be an absolute URI")
        }
        val authorityStart = schemeSeparator + 3
        val authorityEnd = value.indexOfAny(charArrayOf('/', '?', '#'), authorityStart)
        val authority = value.substring(authorityStart, if (authorityEnd < 0) value.length else authorityEnd)
        if (authority.isEmpty() || authority.any { it.isWhitespace() || it.code < 0x21 || it == '\\' } ||
            authority.contains('@')
        ) {
            fail(DefinitionDecodeError.INVALID_ENDPOINT, "submissionEndpoint authority is invalid")
        }
        validateAuthority(authority)
    }

    private fun validateAuthority(authority: String) {
        if (authority.startsWith("[")) {
            val closingBracket = authority.indexOf(']')
            if (closingBracket <= 1 || authority.substring(closingBracket + 1).contains(']')) {
                fail(DefinitionDecodeError.INVALID_ENDPOINT, "submissionEndpoint IPv6 authority is invalid")
            }
            val host = authority.substring(1, closingBracket)
            if (parseIpv6Groups(host) == null) {
                fail(DefinitionDecodeError.INVALID_ENDPOINT, "submissionEndpoint IPv6 authority is invalid")
            }
            validatePortSuffix(authority.substring(closingBracket + 1))
            return
        }
        if ('[' in authority || ']' in authority || authority.count { it == ':' } > 1) {
            fail(DefinitionDecodeError.INVALID_ENDPOINT, "submissionEndpoint IPv6 host must be bracketed")
        }
        val colon = authority.indexOf(':')
        val host = if (colon < 0) authority else authority.substring(0, colon)
        if (host.isEmpty()) {
            fail(DefinitionDecodeError.INVALID_ENDPOINT, "submissionEndpoint host is empty")
        }
        if (colon >= 0) validatePortSuffix(authority.substring(colon))
        validateAsciiHost(host)
    }

    private fun validateAsciiHost(host: String) {
        if (host.any { it.code >= 0x80 || it == '%' }) {
            fail(DefinitionDecodeError.INVALID_ENDPOINT, "submissionEndpoint host must be ASCII without percent-encoding")
        }
        val labels = host.split('.')
        val isDecimalQuad = labels.size == 4 && labels.all { label ->
            label.isNotEmpty() && label.all { character -> character in '0'..'9' }
        }
        if (isDecimalQuad) {
            labels.forEach { label ->
                if ((label.length > 1 && label[0] == '0') ||
                    label.toIntOrNull()?.takeIf { it in 0..255 } == null
                ) {
                    fail(DefinitionDecodeError.INVALID_ENDPOINT, "submissionEndpoint IPv4 host is invalid")
                }
            }
            return
        }
        if (labels.any { label ->
                label.isEmpty() ||
                    label.first() == '-' ||
                    label.last() == '-' ||
                    label.any { character ->
                        character !in 'A'..'Z' && character !in 'a'..'z' &&
                            character !in '0'..'9' && character != '-'
                    }
            }
        ) {
            fail(DefinitionDecodeError.INVALID_ENDPOINT, "submissionEndpoint domain host is invalid")
        }
    }

    private fun validatePortSuffix(suffix: String) {
        if (suffix.isEmpty()) return
        if (!suffix.startsWith(":") || suffix.length == 1 ||
            suffix.substring(1).any { it !in '0'..'9' }
        ) {
            fail(DefinitionDecodeError.INVALID_ENDPOINT, "submissionEndpoint port is invalid")
        }
        val digits = suffix.substring(1).dropWhile { it == '0' }
        val port = digits.toIntOrNull()
        if (digits.isEmpty() || port == null || port !in 1..65_535) {
            fail(DefinitionDecodeError.INVALID_ENDPOINT, "submissionEndpoint port is invalid")
        }
    }

    /**
     * WHATWG URL rejects bracketed hosts that are not IPv6 literals. Keep the common parser
     * independent of java.net so the same check runs in the Android host and iOS native tests.
     */
    private fun parseIpv6Groups(value: String): List<Int>? {
        if (value.isEmpty() || '%' in value) return null
        val compression = value.indexOf("::")
        if (compression >= 0 && value.indexOf("::", compression + 2) >= 0) return null

        val leftText = if (compression >= 0) value.substring(0, compression) else value
        val rightText = if (compression >= 0) value.substring(compression + 2) else ""
        // An embedded IPv4 address expands to the final two 16-bit groups. It can therefore
        // only occur on the right of ::, or at the end of an uncompressed address; placing it
        // before a trailing compression would leave groups after the IPv4 address.
        if (compression >= 0 && leftText.contains('.')) return null
        val left = parseIpv6Part(leftText) ?: return null
        val right = if (compression >= 0) parseIpv6Part(rightText) ?: return null else emptyList()
        val groupCount = left.size + right.size
        return if (compression >= 0) {
            if (groupCount >= 8) return null
            left + List(8 - groupCount) { 0 } + right
        } else {
            groupCount.takeIf { it == 8 }?.let { left }
        }
    }

    private fun parseIpv6Part(value: String): List<Int>? {
        if (value.isEmpty()) return emptyList()
        if (value.startsWith(':') || value.endsWith(':')) return null
        val groups = mutableListOf<Int>()
        val components = value.split(':')
        components.forEachIndexed { index, component ->
            if (component.contains('.')) {
                if (index != components.lastIndex) return null
                val ipv4 = component.split('.')
                if (ipv4.size != 4 || ipv4.any { octet ->
                        octet.isEmpty() ||
                            (octet.length > 1 && octet[0] == '0') ||
                            octet.any { character -> character !in '0'..'9' }
                    }
                ) {
                    return null
                }
                ipv4.forEach {
                    if (it.toIntOrNull() !in 0..255) return null
                }
                groups += (ipv4[0].toInt() shl 8) or ipv4[1].toInt()
                groups += (ipv4[2].toInt() shl 8) or ipv4[3].toInt()
            } else {
                if (component.length !in 1..4 ||
                    component.any { it !in '0'..'9' && it.lowercaseChar() !in 'a'..'f' }
                ) {
                    return null
                }
                groups += component.toInt(16)
            }
        }
        return groups
    }

    private fun RawDefinition.toPublic(authorityKey: CompressedSecp256k1PublicKey): EventDefinition =
        EventDefinition(
            version = version,
            eventId = ByteString32(eventId),
            registrar = Address20(registrar),
            anchorOperator = Address20(anchorOperator),
            nonce = ByteString32(nonce),
            keySetDigest = ByteString32(keySetDigest),
            sequence = sequence,
            previousDefinitionDigest = ByteString32(previousDefinitionDigest),
            receiptPublicKey = receiptPublicKey,
            operatorId = operatorId,
            submissionEndpoint = submissionEndpoint,
            validFrom = validFrom,
            validUntil = validUntil,
            authorityPublicKey = authorityKey,
            joinMode = joinMode,
            eventCodeHash = eventCodeHash,
        )

    private data class ProtectedHeaders(val kid: ByteArray)

    private data class ParsedSignedDefinition(
        val protectedBytes: ByteArray,
        val payloadBytes: ByteArray,
        val signature: ByteArray,
        val protectedHeaders: ProtectedHeaders,
        val definition: RawDefinition,
    )

    private data class RawDefinition(
        val version: Int,
        val eventId: ByteArray,
        val registrar: ByteArray,
        val anchorOperator: ByteArray,
        val nonce: ByteArray,
        val keySetDigest: ByteArray,
        val sequence: ProtocolUInt,
        val previousDefinitionDigest: ByteArray,
        val receiptPublicKey: CompressedSecp256k1PublicKey,
        val operatorId: ByteString32,
        val submissionEndpoint: String,
        val validFrom: ProtocolUInt,
        val validUntil: ProtocolUInt,
        val joinMode: EventJoinMode?,
        val eventCodeHash: ByteArray?,
    )

    private fun fail(reason: DefinitionDecodeError, message: String): Nothing =
        throw DefinitionDecodeException(reason, message)

    internal class StrictCborReader(private val bytes: ByteArray) {
        private var offset: Int = 0

        fun expectTag(expected: Long) {
            val initial = readByte()
            require(initial ushr 5 == 6) { "expected a CBOR tag" }
            require(readAdditional(initial and 0x1f) == expected) { "unexpected CBOR tag" }
        }

        fun expectArray(expectedLength: Int) {
            require(readLength(4) == expectedLength) { "unexpected CBOR array length" }
        }

        fun expectMap(expectedLength: Int) {
            require(readLength(5) == expectedLength) { "unexpected CBOR map length" }
        }

        fun readMapLength(): Int = readLength(5)

        fun expectUnsignedKey(expected: Long) {
            require(readUnsigned() == expected) { "unknown, duplicate, or out-of-order CBOR map key" }
        }

        fun readUnsigned(): Long {
            val initial = readByte()
            require(initial ushr 5 == 0) { "expected CBOR unsigned integer" }
            return readAdditional(initial and 0x1f)
        }

        fun readNegative(): Long {
            val initial = readByte()
            require(initial ushr 5 == 1) { "expected CBOR negative integer" }
            val magnitude = readAdditional(initial and 0x1f)
            return -1L - magnitude
        }

        fun readProtocolUInt(label: String): ProtocolUInt {
            val value = readUnsigned()
            if (value > PROTOCOL_SAFE_UINT_MAX) {
                fail(DefinitionDecodeError.MALFORMED, "$label exceeds the protocol safe integer maximum")
            }
            return ProtocolUInt(value)
        }

        fun readArrayLength(): Int {
            val length = readLength(4)
            return length
        }

        fun readByteString(expectedLength: Int? = null): ByteArray {
            val length = readLength(2)
            if (expectedLength != null && length != expectedLength) {
                throw IllegalArgumentException("unexpected CBOR byte-string length")
            }
            require(length <= bytes.size - offset) { "truncated CBOR byte string" }
            return bytes.copyOfRange(offset, offset + length).also { offset += length }
        }

        fun readText(maxUtf8Bytes: Int): String {
            val length = readLength(3)
            require(length <= maxUtf8Bytes) { "CBOR text string exceeds its protocol length" }
            require(length <= bytes.size - offset) { "truncated CBOR text string" }
            val result = try {
                bytes.copyOfRange(offset, offset + length).decodeToString(throwOnInvalidSequence = true)
            } catch (error: Throwable) {
                throw IllegalArgumentException("CBOR text string is not valid UTF-8", error)
            }
            offset += length
            return result
        }

        fun requireFinished() {
            require(offset == bytes.size) { "trailing bytes after canonical CBOR value" }
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
            require(offset < bytes.size) { "truncated canonical CBOR" }
            return bytes[offset++].toInt() and 0xff
        }
    }
}

private fun compareLexicographically(left: ByteArray, right: ByteArray): Int {
    val common = minOf(left.size, right.size)
    for (index in 0 until common) {
        val l = left[index].toInt() and 0xff
        val r = right[index].toInt() and 0xff
        if (l != r) return l - r
    }
    return left.size - right.size
}

private const val PROTOCOL_SAFE_UINT_MAX: Long = 9_007_199_254_740_991L

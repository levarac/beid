package org.levarac.parallax.registry

import org.levarac.parallax.observation.ByteString32
import org.levarac.parallax.observation.CompressedSecp256k1PublicKey
import org.levarac.parallax.observation.ImmutableBytes
import org.levarac.parallax.observation.ProtocolUInt

internal const val MAX_EVENT_DEFINITION_PAYLOAD_BYTES: Int = 512 * 1_024

/** A defensive-copy Ethereum address used by the canonical event preimage. */
public class Address20 internal constructor(bytes: ByteArray) :
    ImmutableBytes(bytes.requireLength(20, "Ethereum address"))

/** The canonical EventKeySet/v1 artifact committed by the Parallax protocol. */
public class EventKeySet internal constructor(
    public val version: Int,
    authorityKeys: List<CompressedSecp256k1PublicKey>,
    public val threshold: Int,
) {
    /** A defensive snapshot; callers cannot mutate the verified key set. */
    public val authorityKeys: List<CompressedSecp256k1PublicKey> = authorityKeys.toList()

    public val authorityKeyCount: Int
        get() = authorityKeys.size

    public fun authorityKeyAt(index: Int): CompressedSecp256k1PublicKey? = authorityKeys.getOrNull(index)
}

/**
 * The canonical event-definition-v1 payload carried inside COSE_Sign1.
 *
 * The byte-bearing protocol values use defensive-copy wrappers. Numeric protocol values use
 * ProtocolUInt so a native caller cannot accidentally construct a value outside the CBOR-safe
 * integer range.
 */
public class EventDefinition internal constructor(
    public val version: Int,
    public val eventId: ByteString32,
    public val registrar: Address20,
    public val anchorOperator: Address20,
    public val nonce: ByteString32,
    public val keySetDigest: ByteString32,
    public val sequence: ProtocolUInt,
    public val previousDefinitionDigest: ByteString32,
    public val receiptPublicKey: CompressedSecp256k1PublicKey,
    public val operatorId: ByteString32,
    public val submissionEndpoint: String,
    public val validFrom: ProtocolUInt,
    public val validUntil: ProtocolUInt,
    /** The authority key that verified the COSE signature for this definition. */
    public val authorityPublicKey: CompressedSecp256k1PublicKey,
) {
    public val eventIdHex: String
        get() = eventId.toByteArray().toPrefixedHex()

    public val registrarHex: String
        get() = registrar.toByteArray().toPrefixedHex()

    public val anchorOperatorHex: String
        get() = anchorOperator.toByteArray().toPrefixedHex()

    public val keySetDigestHex: String
        get() = keySetDigest.toByteArray().toPrefixedHex()

    public val previousDefinitionDigestHex: String
        get() = previousDefinitionDigest.toByteArray().toPrefixedHex()
}

private fun ByteArray.requireLength(expected: Int, name: String): ByteArray {
    require(size == expected) { "$name must be exactly $expected bytes" }
    return this
}

/**
 * One chain-selected definition together with its verified canonical off-chain artifact.
 *
 * These fields are intentionally repeated at the context boundary. Native callers should not
 * need to know which nested model owns a protocol decision, and each value remains immutable.
 */
public class EventDefinitionContext internal constructor(
    public val eventIdHex: String,
    public val definitionHashHex: String,
    public val selectedAt: Long,
    public val record: RegistryDefinitionRecord,
    public val definition: EventDefinition,
) {
    public val eventId: ByteString32
        get() = definition.eventId

    public val receiptPublicKey: CompressedSecp256k1PublicKey
        get() = definition.receiptPublicKey

    public val operatorId: ByteString32
        get() = definition.operatorId

    public val submissionEndpoint: String
        get() = definition.submissionEndpoint

    public val validFrom: ProtocolUInt
        get() = definition.validFrom

    public val validUntil: ProtocolUInt
        get() = definition.validUntil
}

public enum class DefinitionDecodeError {
    MALFORMED,
    UNSUPPORTED_VERSION,
    INVALID_VALIDITY,
    INVALID_ENDPOINT,
    INVALID_KEY_SET,
    INVALID_COSE,
    INVALID_SIGNATURE,
    EVENT_ID_MISMATCH,
    OPERATOR_ID_MISMATCH,
    KEY_SET_DIGEST_MISMATCH,
    ANCHOR_MISMATCH,
    DEFINITION_HASH_MISMATCH,
}

public class DefinitionDecodeException(
    public val reason: DefinitionDecodeError,
    message: String,
    cause: Throwable? = null,
) : IllegalArgumentException(message, cause)

public enum class DefinitionFetchError {
    NOT_CONFIGURED,
    INVALID_URL_TEMPLATE,
    INVALID_KEY_SET,
    KEY_SET_NOT_CONFIGURED,
    HTTP_ERROR,
    HASH_MISMATCH,
    DECODE_ERROR,
    EVENT_ID_MISMATCH,
    VALIDITY_MISMATCH,
    PAYLOAD_TOO_LARGE,
}

public class DefinitionFetchException(
    public val reason: DefinitionFetchError,
    message: String,
    cause: Throwable? = null,
) : IllegalArgumentException(message, cause)

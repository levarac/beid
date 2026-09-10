package org.levarac.parallax.registry

import org.levarac.parallax.observation.ByteString32
import org.levarac.parallax.observation.CompressedSecp256k1PublicKey
import org.levarac.parallax.observation.ImmutableBytes
import org.levarac.parallax.observation.ProtocolUInt

internal const val MAX_EVENT_DEFINITION_PAYLOAD_BYTES: Int = 512 * 1_024

/** Admission mode explicitly covered by an EventDefinition v1 authority signature. */
public enum class EventJoinMode {
    OPEN,
    GATED,
}

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
 * A reserved organizer claim (EventDefinition v1 label 16).
 *
 * [method] names an entry in the specification's method registry and [data] is opaque to this
 * version. v1.0 reserves the slot and implements no method, so an unrecognised [method] is
 * retained and surfaced as unverified rather than causing the definition to be rejected.
 */
public class OrganizerClaim internal constructor(
    public val method: Long,
    data: ByteArray,
) {
    private val dataBytes: ByteArray = data.copyOf()

    /** A defensive copy; callers cannot mutate the verified claim. */
    public fun dataToByteArray(): ByteArray = dataBytes.copyOf()

    public val dataHex: String
        get() = dataBytes.toPrefixedHex()

    /**
     * Always false in v1.0, which implements no method. A later version returns true only for a
     * method it recognises AND has checked; it must never return true merely because a claim is
     * present and well formed.
     */
    public val isVerified: Boolean
        get() = false
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
    /** Null only for legacy key-1-through-13 definitions, which are never open-discoverable. */
    public val joinMode: EventJoinMode? = null,
    eventCodeHash: ByteArray? = null,
    /** The reserved organizer claim at label 16, retained verbatim when present. */
    public val organizerClaim: OrganizerClaim? = null,
) {
    private val eventCodeHashBytes: ByteArray? = eventCodeHash?.copyOf()

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

    /** The optional B005 event-code hash cryptographically covered by this definition. */
    public val eventCodeHashHex: String?
        get() = eventCodeHashBytes?.toPrefixedHex()?.removePrefix("0x")
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

    public val joinMode: EventJoinMode?
        get() = definition.joinMode

    public val eventCodeHashHex: String?
        get() = definition.eventCodeHashHex
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
    KEY_SET_INVALID_URL_TEMPLATE,
    INVALID_KEY_SET,
    KEY_SET_NOT_CONFIGURED,
    KEY_SET_HTTP_ERROR,
    KEY_SET_HASH_MISMATCH,
    KEY_SET_PAYLOAD_TOO_LARGE,
    HTTP_ERROR,
    HASH_MISMATCH,
    DECODE_ERROR,
    EVENT_ID_MISMATCH,

    /**
     * The registry has no definition record at all for this event ID —
     * distinct from [VALIDITY_MISMATCH], where records exist but none
     * covers the requested time. Callers that need to tell "this event was
     * never registered" apart from "this event's registration has a
     * validity gap right now" (e.g. beid#258 dispatch#2's UI-visible
     * verification indicator) must not collapse the two.
     */
    NOT_FOUND,
    VALIDITY_MISMATCH,
    PAYLOAD_TOO_LARGE,
}

public class DefinitionFetchException(
    public val reason: DefinitionFetchError,
    message: String,
    cause: Throwable? = null,
) : IllegalArgumentException(message, cause)

/**
 * Failure modes for [EventCodeLookupFetcher] (beid#258 P1-1 interim
 * mechanism). This lookup is a routing hint, not a trust boundary — its
 * result is only ever used as an input to [RegistryClient.resolveEventDefinition],
 * which independently verifies it on-chain. See dispatch#21 for the durable,
 * cryptographically-bound replacement.
 */
public enum class EventCodeLookupError {
    NOT_CONFIGURED,
    INVALID_URL_TEMPLATE,
    HTTP_ERROR,
    NOT_FOUND,
    INVALID_RESPONSE,
}

public class EventCodeLookupException(
    public val reason: EventCodeLookupError,
    message: String,
    cause: Throwable? = null,
) : IllegalArgumentException(message, cause)

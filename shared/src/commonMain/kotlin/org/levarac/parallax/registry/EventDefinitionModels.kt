package org.levarac.parallax.registry

internal const val MAX_EVENT_DEFINITION_PAYLOAD_BYTES: Int = 512 * 1_024
internal const val MAX_EVENT_DEFINITION_DELEGATIONS: Int = 1_024

/**
 * The two assignment meanings currently defined by the beid demo schema.
 *
 * These are deliberately bit values, not an enum ordinal. A certificate may
 * carry more than one role, while the signed bytes remain extensible only by a
 * deliberate schema change rather than by silently accepting an unknown bit.
 */
public object DelegationRoles {
    public const val RECEPTION: Long = 1L shl 0
    public const val BOOTH_A: Long = 1L shl 1

    internal const val KNOWN_MASK: Long = RECEPTION or BOOTH_A
}

/** A role assignment signed by an authority key from the event's key set. */
public class DelegationCert internal constructor(
    public val schemaVersion: Int,
    public val eventIdHex: String,
    public val subjectKeyIdHex: String,
    public val roleBits: Long,
    public val issuedAt: Long,
    public val validFrom: Long,
    public val validUntil: Long,
    public val issuerKeyIdHex: String,
    public val signatureHex: String,
) {
    public fun hasRole(role: Long): Boolean = role > 0L && role and roleBits == role

    public fun isValidAt(epochSeconds: Long): Boolean =
        epochSeconds >= validFrom && epochSeconds <= validUntil
}

/**
 * The signed off-chain EventDefinition/v1 payload.
 *
 * Barnard 0.3.0 does not publish an EventDefinition or DelegationCert schema.
 * This minimal CBOR schema therefore belongs to this registry module for this
 * slice. It carries authority signatures and key IDs, plus the operator
 * submission endpoint and the compressed receipt-verification public key. The
 * registry module does not execute authority signature verification: the
 * on-chain key-set commitment is the trust anchor, and key-set retrieval plus
 * Barnard signature execution remain native/SDK responsibilities. Submission
 * code must use the endpoint and receipt key from this verified context rather
 * than independently configured Info.plist values.
 */
public class EventDefinition internal constructor(
    public val schemaVersion: Int,
    public val eventIdHex: String,
    public val validFrom: Long,
    public val validUntil: Long,
    public val signedAt: Long,
    public val authorityKeyIdHex: String,
    public val authoritySignatureHex: String,
    public val submissionEndpoint: String,
    public val receiptPublicKeyHex: String,
    internal val delegations: List<DelegationCert>,
) {
    public val delegationCount: Int
        get() = delegations.size

    public fun delegationAt(index: Int): DelegationCert? = delegations.getOrNull(index)

    public fun activeDelegationCount(epochSeconds: Long): Int =
        delegations.count { it.isValidAt(epochSeconds) }

    public fun activeDelegationAt(epochSeconds: Long, index: Int): DelegationCert? =
        delegations.filter { it.isValidAt(epochSeconds) }.getOrNull(index)
}

/**
 * A definition selected from the chain at one use time and then verified from
 * the off-chain bytes named by that chain record.
 */
public class EventDefinitionContext internal constructor(
    public val eventIdHex: String,
    public val definitionHashHex: String,
    public val selectedAt: Long,
    public val record: RegistryDefinitionRecord,
    public val definition: EventDefinition,
) {
    public val activeDelegationCount: Int
        get() = definition.activeDelegationCount(selectedAt)

    public fun activeDelegationAt(index: Int): DelegationCert? =
        definition.activeDelegationAt(selectedAt, index)
}

public enum class DefinitionDecodeError {
    MALFORMED,
    UNSUPPORTED_VERSION,
    INVALID_VALIDITY,
    FORWARD_VALIDITY,
    INVALID_ROLE,
    INVALID_SIGNATURE,
    INVALID_SUBMISSION_ENDPOINT,
    INVALID_RECEIPT_PUBLIC_KEY,
    EVENT_ID_MISMATCH,
}

public class DefinitionDecodeException(
    public val reason: DefinitionDecodeError,
    message: String,
    cause: Throwable? = null,
) : IllegalArgumentException(message, cause)

public enum class DefinitionFetchError {
    NOT_CONFIGURED,
    INVALID_URL_TEMPLATE,
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

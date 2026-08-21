package org.levarac.parallax.observation

/** A defensive-copy byte container for values that cross the native/shared boundary. */
public open class ImmutableBytes(bytes: ByteArray) {
    private val value: ByteArray = bytes.copyOf()

    public val size: Int
        get() = value.size

    public fun toByteArray(): ByteArray = value.copyOf()

    internal fun copyBytes(): ByteArray = value.copyOf()

    override fun equals(other: Any?): Boolean =
        other is ImmutableBytes && value.contentEquals(other.value)

    override fun hashCode(): Int = value.contentHashCode()

    override fun toString(): String = value.toHex()
}

public class UuidBytes16(bytes: ByteArray) : ImmutableBytes(bytes.requireLength(16, "id"))

public open class ByteString32(bytes: ByteArray) : ImmutableBytes(bytes.requireLength(32, "32-byte value"))

public class BarnardRpid17(bytes: ByteArray) : ImmutableBytes(bytes.requireLength(17, "RPID"))

public class CompressedSecp256k1PublicKey(bytes: ByteArray) :
    ImmutableBytes(bytes.requireLength(33, "compressed secp256k1 public key"))

public class ProtocolUInt(public val value: Long) {
    init {
        require(value in 0..PROTOCOL_SAFE_UINT_MAX) {
            "protocol uint must be between 0 and $PROTOCOL_SAFE_UINT_MAX"
        }
    }

    override fun equals(other: Any?): Boolean = other is ProtocolUInt && value == other.value

    override fun hashCode(): Int = value.hashCode()

    override fun toString(): String = value.toString()
}

public class ObservationCborBytes(bytes: ByteArray) : ImmutableBytes(bytes)

public class SigStructureBytes(bytes: ByteArray) : ImmutableBytes(bytes)

public class Sha256Digest(bytes: ByteArray) : ByteString32(bytes)

public class CompactEs256kSignature(r: ByteArray, s: ByteArray) {
    public val r: ByteString32 = ByteString32(r)
    public val s: ByteString32 = ByteString32(s)

    public fun toByteArray(): ByteArray = r.toByteArray() + s.toByteArray()
}

/**
 * Lossless evidence captured at the window-close boundary.
 *
 * The iOS hook is deliberately not wired in this change. The current capture seam is
 * `SensingCoordinator.closeWindow` (`ios/Beid/Sensing/SensingCoordinator.swift:1576-1643`):
 * it reads `currentWindowRpids` at line 1596 and clears that set at line 1643. A future
 * native adapter must snapshot the 17-byte RPIDs before that clear; a persisted count-only
 * WindowReport is permanently ineligible and must not be converted here.
 */
public data class MutualSensingWindowEvidence(
    public val id: UuidBytes16,
    public val eventId: ByteString32,
    public val eventDefinitionDigest: ByteString32,
    public val observer: CompressedSecp256k1PublicKey,
    public val finalizedAt: Double,
    public val reporterRpid: BarnardRpid17,
    public val enin: ProtocolUInt,
    /** Null is deliberate: a legacy count-only record has no lossless RPID set. */
    public val observedRpids: List<BarnardRpid17>?,
    public val rpidClaim: ImmutableBytes? = null,
    /** Kept as source text so malformed present values become typed ineligibility. */
    public val participantCommitmentHex: String? = null,
    public val legacyPeerCount: Long? = null,
)

public data class MutualSensingPayloadV1(
    public val eventDefinitionDigest: ByteString32,
    public val enin: ProtocolUInt,
    public val observedRpids: List<BarnardRpid17>,
    public val rpidClaim: ImmutableBytes?,
    public val participantCommitment: ByteString32?,
)

public data class ObservationV1(
    public val version: Int,
    public val id: UuidBytes16,
    public val profile: String,
    public val context: ByteString32,
    public val observer: CompressedSecp256k1PublicKey,
    public val observedAt: ProtocolUInt,
    public val subject: BarnardRpid17,
    public val payload: ImmutableBytes,
)

public class PreparedObservationV1 internal constructor(
    public val observation: ObservationV1,
    public val observationPayload: MutualSensingPayloadV1,
    public val observationCbor: ObservationCborBytes,
    public val protectedHeaders: ImmutableBytes,
    public val sigStructure: SigStructureBytes,
    public val sha256Digest: Sha256Digest,
) {
    /** The canonical COSE Sig_structure bytes, before any signer-side hashing. */
    public val signatureStructure: SigStructureBytes
        get() = sigStructure

    /** Sign once through the native key owner, then verify before producing COSE bytes. */
    public fun sign(signer: SignerPort): SignedObservationV1 {
        require(signer.publicKey == observation.observer) {
            "signer public key does not match the Observation observer"
        }
        val request = when (signer.inputMode) {
            SignerInputMode.SIG_STRUCTURE -> SigningRequest.SigStructure(sigStructure)
            SignerInputMode.SHA256_DIGEST -> SigningRequest.Digest(sha256Digest)
        }
        val signature = signer.sign(request)
        if (!Secp256k1.verify(
                digest = sha256Digest.toByteArray(),
                signature = signature,
                publicKey = observation.observer.toByteArray(),
            )
        ) {
            throw InvalidObservationSignatureException(
                "signer returned a signature that does not verify for the prepared Sig_structure",
            )
        }
        val cose = CanonicalCbor.encodeTag(
            tag = COSE_SIGN1_TAG,
            value = CanonicalCbor.array(
                CanonicalCbor.bytes(protectedHeaders.toByteArray()),
                CanonicalCbor.map(),
                CanonicalCbor.bytes(observationCbor.toByteArray()),
                CanonicalCbor.bytes(signature.toByteArray()),
            ),
        )
        return SignedObservationV1(ImmutableBytes(cose), observation, observationPayload)
    }
}

public class SignedObservationV1 internal constructor(
    public val cose: ImmutableBytes,
    public val observation: ObservationV1,
    public val observationPayload: MutualSensingPayloadV1,
)

public enum class ObservationIneligibilityCode(public val wireName: String) {
    LEGACY_COUNT_ONLY("legacy-count-only"),
    MISSING_OBSERVED_RPID_SET("missing-observed-rpid-set"),
    MALFORMED_PARTICIPANT_COMMITMENT("malformed-participant-commitment"),
    MALFORMED_REPORTER_RPID("malformed-reporter-rpid"),
    MALFORMED_OBSERVED_RPID("malformed-observed-rpid"),
    DUPLICATE_OBSERVED_RPID("duplicate-observed-rpid"),
    INVALID_WINDOW_INPUT("invalid-window-input"),
}

public sealed interface ObservationPreparationResult {
    public val eligible: Boolean

    public class Eligible(
        public val prepared: PreparedObservationV1,
    ) : ObservationPreparationResult {
        override val eligible: Boolean = true
    }

    public class Ineligible(
        public val code: ObservationIneligibilityCode,
    ) : ObservationPreparationResult {
        override val eligible: Boolean = false
    }
}

public enum class SignerInputMode {
    SIG_STRUCTURE,
    SHA256_DIGEST,
}

public sealed interface SigningRequest {
    public class SigStructure(
        public val bytes: SigStructureBytes,
    ) : SigningRequest

    public class Digest(
        public val digest: org.levarac.parallax.observation.Sha256Digest,
    ) : SigningRequest
}

public interface SignerPort {
    public val publicKey: CompressedSecp256k1PublicKey
    public val inputMode: SignerInputMode

    public fun sign(request: SigningRequest): CompactEs256kSignature
}

public class InvalidObservationSignatureException(message: String) : IllegalArgumentException(message)

internal const val PROTOCOL_SAFE_UINT_MAX: Long = 9_007_199_254_740_991L
internal const val OBSERVATION_PROFILE: String = "levarac.mutual-sensing/v1"
internal const val OBSERVATION_CONTENT_TYPE: String = "application/vnd.levarac.observation+cbor"
internal const val COSE_SIGN1_TAG: Long = 18

private fun ByteArray.requireLength(expected: Int, name: String): ByteArray {
    require(size == expected) { "$name must be exactly $expected bytes" }
    return this
}

internal fun ByteArray.toHex(): String = buildString(size * 2) {
    for (byte in this@toHex) {
        val value = byte.toInt() and 0xff
        append("0123456789abcdef"[value ushr 4])
        append("0123456789abcdef"[value and 0x0f])
    }
}

package org.levarac.parallax.observation

private class ReadOnlyList<T>(values: List<T>) : List<T> by values.toList()

private fun <T> readOnlySnapshot(values: List<T>): List<T> = ReadOnlyList(values)

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
 * The iOS adapter wires this evidence at `SensingCoordinator.closeWindow`: it snapshots
 * the 17-byte RPIDs before the native window state is cleared. A persisted count-only
 * WindowReport is permanently ineligible and must not be converted here.
 */
public class MutualSensingWindowEvidence(
    public val id: UuidBytes16,
    public val eventId: ByteString32,
    public val eventDefinitionDigest: ByteString32,
    public val observer: CompressedSecp256k1PublicKey,
    public val finalizedAt: Double,
    public val reporterRpid: BarnardRpid17,
    public val enin: ProtocolUInt,
    /** Raw bytes remain available so malformed RPID evidence can become typed ineligibility. */
    observedRpids: List<ImmutableBytes>?,
    rpidClaim: ImmutableBytes? = null,
    /** Kept as source text so malformed present values become typed ineligibility. */
    public val participantCommitmentHex: String? = null,
    public val legacyPeerCount: Long? = null,
) {
    /** Null is deliberate: a legacy count-only record has no lossless RPID set. */
    public val observedRpids: List<ImmutableBytes>? = observedRpids?.let { values ->
        readOnlySnapshot(values.map {
            ImmutableBytes(it.toByteArray())
        })
    }

    public val rpidClaim: ImmutableBytes? = rpidClaim?.let { ImmutableBytes(it.toByteArray()) }

    public fun copy(
        id: UuidBytes16 = this.id,
        eventId: ByteString32 = this.eventId,
        eventDefinitionDigest: ByteString32 = this.eventDefinitionDigest,
        observer: CompressedSecp256k1PublicKey = this.observer,
        finalizedAt: Double = this.finalizedAt,
        reporterRpid: BarnardRpid17 = this.reporterRpid,
        enin: ProtocolUInt = this.enin,
        observedRpids: List<ImmutableBytes>? = this.observedRpids,
        rpidClaim: ImmutableBytes? = this.rpidClaim,
        participantCommitmentHex: String? = this.participantCommitmentHex,
        legacyPeerCount: Long? = this.legacyPeerCount,
    ): MutualSensingWindowEvidence = MutualSensingWindowEvidence(
        id = id,
        eventId = eventId,
        eventDefinitionDigest = eventDefinitionDigest,
        observer = observer,
        finalizedAt = finalizedAt,
        reporterRpid = reporterRpid,
        enin = enin,
        observedRpids = observedRpids,
        rpidClaim = rpidClaim,
        participantCommitmentHex = participantCommitmentHex,
        legacyPeerCount = legacyPeerCount,
    )

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is MutualSensingWindowEvidence) return false
        return id == other.id &&
            eventId == other.eventId &&
            eventDefinitionDigest == other.eventDefinitionDigest &&
            observer == other.observer &&
            finalizedAt == other.finalizedAt &&
            reporterRpid == other.reporterRpid &&
            enin == other.enin &&
            observedRpids == other.observedRpids &&
            rpidClaim == other.rpidClaim &&
            participantCommitmentHex == other.participantCommitmentHex &&
            legacyPeerCount == other.legacyPeerCount
    }

    override fun hashCode(): Int {
        var result = id.hashCode()
        result = 31 * result + eventId.hashCode()
        result = 31 * result + eventDefinitionDigest.hashCode()
        result = 31 * result + observer.hashCode()
        result = 31 * result + finalizedAt.hashCode()
        result = 31 * result + reporterRpid.hashCode()
        result = 31 * result + enin.hashCode()
        result = 31 * result + (observedRpids?.hashCode() ?: 0)
        result = 31 * result + (rpidClaim?.hashCode() ?: 0)
        result = 31 * result + (participantCommitmentHex?.hashCode() ?: 0)
        result = 31 * result + (legacyPeerCount?.hashCode() ?: 0)
        return result
    }
}

public class MutualSensingPayloadV1(
    public val eventDefinitionDigest: ByteString32,
    public val enin: ProtocolUInt,
    observedRpids: List<BarnardRpid17>,
    public val rpidClaim: ImmutableBytes?,
    public val participantCommitment: ByteString32?,
) {
    public val observedRpids: List<BarnardRpid17> = readOnlySnapshot(observedRpids)

    public fun copy(
        eventDefinitionDigest: ByteString32 = this.eventDefinitionDigest,
        enin: ProtocolUInt = this.enin,
        observedRpids: List<BarnardRpid17> = this.observedRpids,
        rpidClaim: ImmutableBytes? = this.rpidClaim,
        participantCommitment: ByteString32? = this.participantCommitment,
    ): MutualSensingPayloadV1 = MutualSensingPayloadV1(
        eventDefinitionDigest = eventDefinitionDigest,
        enin = enin,
        observedRpids = observedRpids,
        rpidClaim = rpidClaim,
        participantCommitment = participantCommitment,
    )

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is MutualSensingPayloadV1) return false
        return eventDefinitionDigest == other.eventDefinitionDigest &&
            enin == other.enin &&
            observedRpids == other.observedRpids &&
            rpidClaim == other.rpidClaim &&
            participantCommitment == other.participantCommitment
    }

    override fun hashCode(): Int {
        var result = eventDefinitionDigest.hashCode()
        result = 31 * result + enin.hashCode()
        result = 31 * result + observedRpids.hashCode()
        result = 31 * result + (rpidClaim?.hashCode() ?: 0)
        result = 31 * result + (participantCommitment?.hashCode() ?: 0)
        return result
    }
}

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
        return signWithCompactSignature(signer.sign(request))
    }

    /**
     * Native bridges may not be able to implement a Swift Export interface or
     * construct Kotlin ByteArray values directly. They still own the signer:
     * this entry point accepts its exact 32-byte compact components as hex and
     * keeps verification and COSE assembly in the shared implementation.
     */
    public fun signWithCompactSignatureHex(
        rHex: String,
        sHex: String,
    ): SignedObservationV1 = signWithCompactSignature(
        CompactEs256kSignature(
            r = decodeFixedHex(rHex, 32, "signature r"),
            s = decodeFixedHex(sHex, 32, "signature s"),
        ),
    )

    private fun signWithCompactSignature(signature: CompactEs256kSignature): SignedObservationV1 {
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

internal fun decodeFixedHex(value: String, expectedBytes: Int, label: String): ByteArray {
    val source = value.removePrefix("0x")
    require(source.length == expectedBytes * 2 && source.all { it.isAsciiHexDigit() }) {
        "$label must be exactly $expectedBytes hexadecimal bytes"
    }
    return ByteArray(expectedBytes) { index ->
        source.substring(index * 2, index * 2 + 2).toInt(16).toByte()
    }
}

private fun Char.isAsciiHexDigit(): Boolean =
    this in '0'..'9' || this in 'a'..'f' || this in 'A'..'F'

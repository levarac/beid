package org.levarac.beid.persistence

import java.time.Instant
import java.util.UUID
import org.levarac.beid.sensing.SensingRecoverableSignature
import org.levarac.beid.sensing.toLowercaseHex

/**
 * Owner-key-signed attestation that this device's per-event signing key `K`
 * observed peers for one event, over ENIN range `[eninStart, eninEnd]`
 * (`docs/specs/barnard-binding-conformance.md` §2.2). A "holder-held
 * artifact" — MUST NOT appear in Advertise data, GATT values, public
 * anchors, or witness blobs.
 *
 * beid's own local record shape (DECISIONS 2026-08-29), field-for-field
 * mirror of iOS's `SelfProofRecord`
 * (`ios/Beid/Persistence/SelfProofRecord.swift`). Attached to the `Proof` it
 * attests to via [proofId] — never embedded inside a proof record itself.
 */
data class SelfProofRecord(
    val id: UUID,
    val proofId: UUID,
    val eventCode: String,
    /** `EventIdHash.compute(eventCode)`, hex-encoded. */
    val eventIdHashHex: String,
    /** Compressed secp256k1 per-event signing public key `K`, hex-encoded. */
    val eventSigningPublicKeyHex: String,
    val eninStart: Long,
    val eninEnd: Long,
    /** Compressed secp256k1 owner public key, hex-encoded. */
    val ownerPublicKeyHex: String,
    val signatureRHex: String,
    val signatureSHex: String,
    val signatureV: Int,
    val signedAt: Instant,
) {
    constructor(
        proofId: UUID,
        eventCode: String,
        eventIdHash: ByteArray,
        eventSigningPublicKey: ByteArray,
        eninStart: Long,
        eninEnd: Long,
        ownerPublicKey: ByteArray,
        signature: SensingRecoverableSignature,
        signedAt: Instant = Instant.now(),
    ) : this(
        id = UUID.randomUUID(),
        proofId = proofId,
        eventCode = eventCode,
        eventIdHashHex = eventIdHash.toLowercaseHex(),
        eventSigningPublicKeyHex = eventSigningPublicKey.toLowercaseHex(),
        eninStart = eninStart,
        eninEnd = eninEnd,
        ownerPublicKeyHex = ownerPublicKey.toLowercaseHex(),
        signatureRHex = signature.r.toLowercaseHex(),
        signatureSHex = signature.s.toLowercaseHex(),
        signatureV = signature.v,
        signedAt = signedAt,
    )
}

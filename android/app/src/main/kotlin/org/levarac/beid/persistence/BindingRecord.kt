package org.levarac.beid.persistence

import java.util.UUID
import org.levarac.beid.sensing.SensingRecoverableSignature
import org.levarac.beid.sensing.toLowercaseHex

/**
 * Evidence that a wallet endorsed this device's app-generated owner key —
 * the combined wallet `personal_sign` (over the `barnard-account-binding:v1`
 * canonical text) + owner-key wallet-ack (`barnard-wallet-ack:v1`) round
 * trip (`docs/specs/barnard-binding-conformance.md` §2.3/§2.4). Mutual
 * signature: valid only with BOTH `walletSignatureHex` AND the owner-key
 * acknowledgement (`deviceSignature*`).
 *
 * This is beid's own local record shape (DECISIONS 2026-08-29: not
 * Barnard's canonical bytes, which this record only carries hex-encoded
 * values *of* — Barnard's own canonical binding text/self-proof/wallet-ack
 * message assembly stays entirely inside `BarnardIdentity`, never
 * re-derived here). Field-for-field mirror of iOS's `BindingRecord`
 * (`ios/Beid/Persistence/BindingRecord.swift`).
 *
 * Attached to the `Proof` it endorses via [proofId] — never embedded inside
 * a proof record itself.
 */
data class BindingRecord(
    val id: UUID,
    val proofId: UUID,
    val eventCode: String,
    val walletAddress: String,
    /** Compressed secp256k1 per-event signing public key `K` active during this session — beid-side bookkeeping only. */
    val eventSigningPublicKeyHex: String,
    /** The owner key the wallet endorsed — embedded in, and covered by, the wallet's EIP-191 signature over the canonical binding text. */
    val ownerPublicKeyHex: String,
    val chainId: Long,
    val nonceHex: String,
    /** RFC 3339 UTC, second precision — the literal string embedded in (and covered by) the signed canonical binding text. */
    val issuedAt: String,
    val walletSignatureHex: String,
    val deviceSignatureRHex: String,
    val deviceSignatureSHex: String,
    val deviceSignatureV: Int,
) {
    constructor(
        proofId: UUID,
        eventCode: String,
        walletAddress: String,
        eventSigningPublicKey: ByteArray,
        ownerPublicKey: ByteArray,
        chainId: Long,
        nonce: ByteArray,
        issuedAt: String,
        walletSignatureHex: String,
        deviceSignature: SensingRecoverableSignature,
    ) : this(
        id = UUID.randomUUID(),
        proofId = proofId,
        eventCode = eventCode,
        walletAddress = walletAddress,
        eventSigningPublicKeyHex = eventSigningPublicKey.toLowercaseHex(),
        ownerPublicKeyHex = ownerPublicKey.toLowercaseHex(),
        chainId = chainId,
        nonceHex = nonce.toLowercaseHex(),
        issuedAt = issuedAt,
        walletSignatureHex = walletSignatureHex,
        deviceSignatureRHex = deviceSignature.r.toLowercaseHex(),
        deviceSignatureSHex = deviceSignature.s.toLowercaseHex(),
        deviceSignatureV = deviceSignature.v,
    )
}

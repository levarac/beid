package org.levarac.beid.persistence

import java.time.Instant
import java.util.UUID

/**
 * A locally collected proof of attendance — the Android counterpart of
 * iOS's `Proof` (`ios/Beid/Models/Proof.swift`), reduced to this slice's
 * scope (beid#121): no `eventName` (Android has no session type to source
 * one from yet — the list shows [eventCode] as-is), no `gradientSeed`
 * (no artwork), no `ProofSignatureState`/wallet-`personal_sign` mirroring
 * (that mechanism is iOS-only and explicitly provisional, see
 * `ios/Beid/Models/ProofSignature.swift`'s own doc comment and beid#33).
 *
 * Signature status here is derived from [hasSelfProof]/[hasBinding] —
 * record *presence* in [org.levarac.beid.persistence.SelfProofRecordStore]/
 * [org.levarac.beid.persistence.BindingRecordStore], the real
 * protocol-relevant mechanism PR #314 already built — rather than a
 * separately tracked lifecycle enum.
 */
data class ProofRecord(
    val id: UUID,
    val eventCode: String,
    val createdAt: Instant,
    /**
     * `var`-equivalent field on an otherwise-immutable record: grows in
     * place while a proof is being recorded, updated via
     * [ProofRecordStore.updatePeersVerified] — mirrors iOS's
     * `Proof.peersVerified` (`ProofStore.updatePeersVerified(for:to:)`).
     */
    val peersVerified: Int,
    val hasSelfProof: Boolean = false,
    val hasBinding: Boolean = false,
)

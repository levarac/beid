package org.levarac.beid.sensing

import android.content.Context
import org.levarac.barnard.BarnardIdentity
import org.levarac.barnard.BarnardRecoverableSignature

/**
 * App-owned, lossless copy of Barnard's recoverable signature components.
 * `r`/`s` remain the exact returned bytes, `v` the raw recovery identifier.
 * Mirrors iOS's `SensingRecoverableSignature`
 * (`ios/Beid/Sensing/SensingCryptography.swift`).
 */
data class SensingRecoverableSignature(val r: ByteArray, val s: ByteArray, val v: Int) {
    override fun equals(other: Any?): Boolean =
        other is SensingRecoverableSignature && r.contentEquals(other.r) && s.contentEquals(other.s) && v == other.v

    override fun hashCode(): Int = r.contentHashCode() * 31 * 31 + s.contentHashCode() * 31 + v
}

internal fun BarnardRecoverableSignature.toSensingSignature(): SensingRecoverableSignature =
    SensingRecoverableSignature(r = r.hexToByteArray(), s = s.hexToByteArray(), v = v)

/**
 * Pure indirection over the cryptographic operations used by owner-key
 * binding/self-proof. Callers retain every lifecycle, payload, validation,
 * and persistence decision; implementations only forward one operation and
 * map its result. Mirrors iOS's `SensingCryptography` protocol
 * (`ios/Beid/Sensing/SensingCryptography.swift`) at the subset this slice
 * needs — the per-event report-signing method (`signWindowReport`) is
 * unrelated to owner-key/binding/self-proof and out of this task's scope
 * (deferred with the rest of report-ledger wiring, beid#121).
 *
 * [buildAccountBindingText] has no iOS counterpart on this protocol: iOS
 * calls `BarnardCoreSigning.buildAccountBindingText` as a static function
 * directly from `BindingMessage`, with no Context/instance involved.
 * Android's `BarnardIdentity` is instance-based (needs a `Context` to
 * construct, even though this particular method never touches it), so this
 * method is a pragmatic Android-specific addition to keep `BindingMessage`
 * free of its own `Context` dependency — see [BindingMessage].
 */
interface SensingCryptography {
    fun eventSigningPublicKey(eventCode: String): ByteArray

    fun ownerPublicKey(): ByteArray

    fun signSelfProof(
        eventIdHash: ByteArray,
        eventSigningPublicKey: ByteArray,
        eninStart: Long,
        eninEnd: Long,
    ): SensingRecoverableSignature?

    fun signWalletAcknowledgement(
        walletAddress: ByteArray,
        walletSignature: ByteArray,
    ): SensingRecoverableSignature?

    fun buildAccountBindingText(
        domain: String,
        walletAddress: ByteArray,
        ownerPublicKey: ByteArray,
        chainId: Long,
        nonce: ByteArray,
        issuedAt: String,
    ): String?
}

/**
 * Production adapter for the Barnard-backed owner-key operations used by
 * event join. Each method makes exactly one [BarnardIdentity]/
 * [OwnerKeyProvider] call and copies its result without adding sensing
 * decisions or re-checking Barnard semantics — mirrors iOS's
 * `BarnardSensingCryptography`. A native testability boundary
 * (AGENTS.md), not a `shared/` decision.
 */
class BarnardSensingCryptography(context: Context) : SensingCryptography {
    private val identity = BarnardIdentity(context)
    internal val ownerKeyProvider = OwnerKeyProvider(
        identity = identity,
        keyStorage = SharedPreferencesOwnerKeyStorage(ownerKeyPreferences(context)),
        randomSource = SecureRandomOwnerKeySource(),
    )

    override fun eventSigningPublicKey(eventCode: String): ByteArray =
        identity.signingPublicKey(eventCode).hexToByteArray()

    override fun ownerPublicKey(): ByteArray = ownerKeyProvider.publicKeyCompressed()

    override fun signSelfProof(
        eventIdHash: ByteArray,
        eventSigningPublicKey: ByteArray,
        eninStart: Long,
        eninEnd: Long,
    ): SensingRecoverableSignature? =
        ownerKeyProvider.signSelfProof(eventIdHash, eventSigningPublicKey, eninStart, eninEnd)

    override fun signWalletAcknowledgement(
        walletAddress: ByteArray,
        walletSignature: ByteArray,
    ): SensingRecoverableSignature? =
        ownerKeyProvider.signWalletAcknowledgement(walletAddress, walletSignature)

    override fun buildAccountBindingText(
        domain: String,
        walletAddress: ByteArray,
        ownerPublicKey: ByteArray,
        chainId: Long,
        nonce: ByteArray,
        issuedAt: String,
    ): String? = identity.buildAccountBindingText(domain, walletAddress, ownerPublicKey, chainId.toULong(), nonce, issuedAt)
}

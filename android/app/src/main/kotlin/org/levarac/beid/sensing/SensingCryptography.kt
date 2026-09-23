package org.levarac.beid.sensing

import android.content.Context
import org.levarac.barnard.BarnardIdentity
import org.levarac.barnard.BarnardRecoverableSignature
import org.levarac.barnard.WalletBindingVerification
import org.levarac.barnard.WalletSignatureClassification

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
 * binding/self-proof and per-event report signing. Callers retain every
 * lifecycle, payload, validation, and persistence decision; implementations
 * only forward one operation and map its result. Mirrors iOS's
 * `SensingCryptography` protocol
 * (`ios/Beid/Sensing/SensingCryptography.swift`) at the subset this slice
 * needs.
 *
 * [signWindowReport] is the signing primitive that per-event report/
 * observation signing needs; it is added now so it is usable by whichever
 * future slice
 * builds the ledger writer, per gh#235's still-open fork decision on what
 * artifact backs the ledger's `persistedObservationReference` (not settled
 * here, and not named here since no fork has been chosen). Building the
 * ledger writer itself remains out of scope for this change.
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

    /**
     * Signs the exact bytes of one already-assembled per-event report
     * (e.g. a window report/observation payload) under the event's signing
     * key. Non-nullable, mirroring iOS's `signWindowReport` — the one
     * signing method on that protocol that returns non-optional, unlike
     * [signSelfProof]/[signWalletAcknowledgement].
     */
    fun signWindowReport(eventCode: String, bytes: ByteArray): SensingRecoverableSignature

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

    /** Barnard's complete EIP-191 wallet + owner-ack verification. */
    fun verifyWalletBinding(
        text: String,
        walletSignature: ByteArray,
        walletAddress: ByteArray,
        ownerPublicKey: ByteArray,
        acknowledgement: SensingRecoverableSignature,
    ): WalletBindingVerification = WalletBindingVerification.VALID

    fun classifyWalletSignature(walletSignature: ByteArray): WalletSignatureClassification =
        if (walletSignature.size == 65) WalletSignatureClassification.VALID_EOA_SHAPE
        else WalletSignatureClassification.INVALID
}

/**
 * Production adapter for the Barnard-backed owner-key operations used by
 * event join. Each method makes exactly one [BarnardIdentity]/
 * [OwnerKeyProvider] call and copies its result without adding sensing
 * decisions or re-checking Barnard semantics — mirrors iOS's
 * `BarnardSensingCryptography`. A native testability boundary
 * (AGENTS.md), not a `shared/` decision.
 */
class BarnardSensingCryptography internal constructor(
    context: Context,
    keyStorage: OwnerKeyStorage,
    randomSource: OwnerKeyRandomSource,
) : SensingCryptography {
    constructor(context: Context) : this(
        context = context,
        keyStorage = AndroidKeystoreOwnerKeyStorage(
            ownerKeyPreferences(context),
            AndroidKeystoreOwnerKeyProtector(),
            durableSnapshot = { sharedPreferencesDurableSnapshot(ownerKeyPreferencesFile(context)) },
        ),
        randomSource = SecureRandomOwnerKeySource(),
    )

    private val identity = BarnardIdentity(context)
    internal val ownerKeyProvider = OwnerKeyProvider(
        identity = identity,
        keyStorage = keyStorage,
        randomSource = randomSource,
    )

    override fun eventSigningPublicKey(eventCode: String): ByteArray =
        identity.signingPublicKey(eventCode).hexToByteArray()

    override fun ownerPublicKey(): ByteArray = ownerKeyProvider.publicKeyCompressed()

    override fun signWindowReport(eventCode: String, bytes: ByteArray): SensingRecoverableSignature =
        identity.sign(eventCode, bytes).toSensingSignature()

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

    override fun verifyWalletBinding(
        text: String,
        walletSignature: ByteArray,
        walletAddress: ByteArray,
        ownerPublicKey: ByteArray,
        acknowledgement: SensingRecoverableSignature,
    ): WalletBindingVerification = identity.verifyWalletBinding(
        text,
        walletSignature,
        walletAddress,
        ownerPublicKey,
        BarnardRecoverableSignature(
            r = acknowledgement.r.joinToString("") { "%02x".format(it.toInt() and 0xff) },
            s = acknowledgement.s.joinToString("") { "%02x".format(it.toInt() and 0xff) },
            v = acknowledgement.v,
        ),
    )

    override fun classifyWalletSignature(walletSignature: ByteArray): WalletSignatureClassification =
        identity.classifyWalletSignature(walletSignature)
}

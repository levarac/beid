package org.levarac.beid.sensing

import android.content.Context
import android.content.SharedPreferences
import java.security.SecureRandom
import org.levarac.barnard.BarnardIdentity

/** Supplies fresh entropy for a first-time seed — a test seam mirroring `BarnardCoreRandomSource` on iOS. */
interface OwnerKeyRandomSource {
    fun randomBytes(count: Int): ByteArray
}

/** [OwnerKeyRandomSource] backed by the platform's cryptographically secure RNG — Android's equivalent of iOS's `SecRandomCopyBytes`-backed `BeidSystemRandomSource`. */
class SecureRandomOwnerKeySource : OwnerKeyRandomSource {
    private val random = SecureRandom()

    override fun randomBytes(count: Int): ByteArray = ByteArray(count).also(random::nextBytes)
}

/**
 * App-generated secp256k1 owner key — the cross-event identity anchor in
 * `commit = H(event signing key ‖ owner key ‖ salt)`. Mirrors
 * `ios/Beid/Sensing/OwnerKeyProvider.swift`'s D1 (2026-07-30): no continuity
 * for v1, the key regenerates per device/reinstall. Reuses
 * `BarnardIdentity`'s already-tested secp256k1
 * derivation (barnard#133/barnard#92) rather than hand-rolling elliptic-curve
 * math in the app layer — see AGENTS.md's KMP-002. The seed is encrypted by
 * an AndroidKeyStore-backed AES-GCM key before it reaches SharedPreferences.
 *
 * The owner private key never leaves this type — only the public key
 * (`publicKeyCompressed()`) and signatures (`signSelfProof`,
 * `signWalletAcknowledgement`) do.
 */
class OwnerKeyProvider(
    private val identity: BarnardIdentity,
    private val keyStorage: OwnerKeyStorage,
    private val randomSource: OwnerKeyRandomSource,
) {
    /** The owner key is stable for the device's lifetime (until reinstall) — cached after a verified read or write. */
    private var cachedKeyPair: BarnardOwnerKeyPairHex? = null
    /** Retains first-install entropy across an in-process failed durable commit. */
    private var pendingGeneratedSeed: ByteArray? = null

    /** Compressed secp256k1 public key — the only owner-key component that ever leaves the device. */
    fun publicKeyCompressed(): ByteArray = keyPair().publicKeyCompressedHex.hexToByteArray()

    /**
     * Owner-key-signed self-proof (`docs/specs/barnard-binding-conformance.md`
     * §2.2) — `null` if `eventIdHash`/`eventSigningPublicKey` fail Barnard's
     * own shape validation.
     */
    fun signSelfProof(
        eventIdHash: ByteArray,
        eventSigningPublicKey: ByteArray,
        eninStart: Long,
        eninEnd: Long,
    ): SensingRecoverableSignature? {
        val pair = keyPair()
        val signature = identity.signSelfProof(
            pair.privateKeyHex,
            eventIdHash,
            eventSigningPublicKey,
            eninStart.toULong(),
            eninEnd.toULong(),
            pair.publicKeyCompressedHex.hexToByteArray(),
        ) ?: return null
        return signature.toSensingSignature()
    }

    /**
     * Owner-key-signed wallet acknowledgement (`docs/specs/barnard-binding-conformance.md`
     * §2.4) — `null` if `walletAddress`/`walletSignature` fail Barnard's own
     * shape validation.
     */
    fun signWalletAcknowledgement(
        walletAddress: ByteArray,
        walletSignature: ByteArray,
    ): SensingRecoverableSignature? {
        val pair = keyPair()
        val signature = identity.signWalletAcknowledgement(
            pair.privateKeyHex,
            walletAddress,
            walletSignature,
        ) ?: return null
        return signature.toSensingSignature()
    }

    private fun keyPair(): BarnardOwnerKeyPairHex {
        cachedKeyPair?.let { return it }

        val seed = when (val stored = keyStorage.readBytes(SEED_KEY)) {
            OwnerKeyReadResult.Missing -> generateAndPersistSeed()
            is OwnerKeyReadResult.Present -> stored.bytes.requireSeedLength().also { pendingGeneratedSeed = null }
            is OwnerKeyReadResult.Failure -> throw OwnerKeyUnavailableException(stored.reason)
        }

        val derived = identity.deriveOwnerKeyPair(seed)
        return BarnardOwnerKeyPairHex(
            privateKeyHex = derived.privateKey,
            publicKeyCompressedHex = derived.publicKeyCompressed,
        ).also { cachedKeyPair = it }
    }

    private fun generateAndPersistSeed(): ByteArray {
        val generated = (pendingGeneratedSeed ?: randomSource.randomBytes(SEED_LENGTH_BYTES).requireSeedLength())
        try {
            keyStorage.putBytes(SEED_KEY, generated)
        } catch (error: OwnerKeyUnavailableException) {
            pendingGeneratedSeed = generated
            throw error
        } catch (error: Exception) {
            pendingGeneratedSeed = generated
            throw OwnerKeyUnavailableException(OwnerKeyStorageFailure.WRITE_FAILED, error)
        }

        val readBack = keyStorage.readBytes(SEED_KEY)
        if (readBack !is OwnerKeyReadResult.Present || !readBack.bytes.contentEquals(generated)) {
            pendingGeneratedSeed = generated
            throw OwnerKeyUnavailableException(OwnerKeyStorageFailure.WRITE_VERIFICATION_FAILED)
        }
        return readBack.bytes.requireSeedLength().also { pendingGeneratedSeed = null }
    }

    private fun ByteArray.requireSeedLength(): ByteArray {
        if (size != SEED_LENGTH_BYTES) {
            throw OwnerKeyUnavailableException(OwnerKeyStorageFailure.CORRUPT)
        }
        return this
    }

    /** Local mirror of `BarnardOwnerKeyPair`'s two hex fields — avoids re-exposing Barnard's own type as this class's cache shape. */
    private data class BarnardOwnerKeyPairHex(val privateKeyHex: String, val publicKeyCompressedHex: String)

    private companion object {
        const val SEED_KEY = "beid.ownerKeySeed"
        const val SEED_LENGTH_BYTES = 32
    }
}

/** Production `SharedPreferences` file for [OwnerKeyProvider]'s seed — separate from Barnard's own `"barnard"` prefs file. */
internal fun ownerKeyPreferences(context: Context): SharedPreferences =
    context.getSharedPreferences("beid_owner_key", Context.MODE_PRIVATE)

internal fun ownerKeyPreferencesFile(context: Context): java.io.File =
    java.io.File(context.applicationInfo.dataDir, "shared_prefs/beid_owner_key.xml")

internal fun ByteArray.toLowercaseHex(): String = joinToString("") { "%02x".format(it) }

internal fun String.hexToByteArray(): ByteArray {
    require(length % 2 == 0) { "hex string must have an even length" }
    return ByteArray(length / 2) { index -> substring(index * 2, index * 2 + 2).toInt(16).toByte() }
}

/**
 * Null-safe hex decode for externally supplied strings (a wallet's own
 * address/signature hex) — unlike [hexToByteArray], malformed input is data,
 * not a programmer error, so this returns `null` rather than throwing. An
 * optional leading `0x`/`0X` is stripped first.
 */
internal fun String.hexToByteArrayOrNull(): ByteArray? {
    val stripped = if (startsWith("0x") || startsWith("0X")) substring(2) else this
    if (stripped.isEmpty() || stripped.length % 2 != 0) return null
    return try {
        ByteArray(stripped.length / 2) { index -> stripped.substring(index * 2, index * 2 + 2).toInt(16).toByte() }
    } catch (_: NumberFormatException) {
        null
    }
}

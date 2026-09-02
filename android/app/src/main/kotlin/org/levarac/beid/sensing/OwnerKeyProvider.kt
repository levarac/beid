package org.levarac.beid.sensing

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import java.security.SecureRandom
import org.levarac.barnard.BarnardIdentity

/** Loads/stores [OwnerKeyProvider]'s 32-byte `accountSecret` seed — a test seam mirroring `BarnardCoreKeyStorage` on iOS. */
interface OwnerKeyStorage {
    fun bytes(key: String): ByteArray?
    fun putBytes(key: String, bytes: ByteArray)
}

/** Supplies fresh entropy for a first-time seed — a test seam mirroring `BarnardCoreRandomSource` on iOS. */
interface OwnerKeyRandomSource {
    fun randomBytes(count: Int): ByteArray
}

/**
 * App-layer `SharedPreferences`-backed [OwnerKeyStorage] — a separate prefs
 * file from Barnard's own `"barnard"` prefs (which hold `DeviceSecret`), so
 * the owner key's storage is independent of, and outlives independently
 * from, the per-event signing identity's. Mirrors iOS's
 * `BeidUserDefaultsKeyStorage` at reduced scope: unlike iOS, this first
 * Android pass does not quarantine a wrong-shaped stored value (gh#156's
 * Signal-A mechanism) — a bad stored value is silently discarded and
 * regenerated. See handoff for why this was judged out of scope for a first
 * pass.
 */
class SharedPreferencesOwnerKeyStorage(
    private val prefs: SharedPreferences,
) : OwnerKeyStorage {
    override fun bytes(key: String): ByteArray? {
        val encoded = prefs.getString(key, null) ?: return null
        return try {
            Base64.decode(encoded, Base64.NO_WRAP)
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    override fun putBytes(key: String, bytes: ByteArray) {
        prefs.edit().putString(key, Base64.encodeToString(bytes, Base64.NO_WRAP)).apply()
    }
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
 * for v1, the key regenerates per device/reinstall, stored at the same
 * level Barnard's own `DeviceSecret` uses today (plain `SharedPreferences`,
 * not Keystore). Reuses `BarnardIdentity`'s already-tested secp256k1
 * derivation (barnard#133/barnard#92) rather than hand-rolling elliptic-curve
 * math in the app layer — see AGENTS.md's KMP-002.
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
    /** The owner key is stable for the device's lifetime (until reinstall) — cached after first derivation. */
    private var cachedKeyPair: BarnardOwnerKeyPairHex? = null

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

        val existing = keyStorage.bytes(SEED_KEY)
        val seed = if (existing != null && existing.size == SEED_LENGTH_BYTES) {
            existing
        } else {
            randomSource.randomBytes(SEED_LENGTH_BYTES).also { keyStorage.putBytes(SEED_KEY, it) }
        }

        val derived = identity.deriveOwnerKeyPair(seed)
        return BarnardOwnerKeyPairHex(
            privateKeyHex = derived.privateKey,
            publicKeyCompressedHex = derived.publicKeyCompressed,
        ).also { cachedKeyPair = it }
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

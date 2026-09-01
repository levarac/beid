package org.levarac.beid.sensing

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.barnard.BarnardIdentity
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Golden-vector conformance for [OwnerKeyProvider] against Barnard's own
 * pinned `deriveOwnerKeyPair`/self-proof/wallet-ack vectors
 * (`levarac/barnard` `test-vectors/owner-key-v1.txt`, v0.5.0 — read directly
 * from source, not beid's own re-derivation). Mirrors
 * `ios/BeidTests/OwnerKeyProviderTests.swift` and
 * `ios/BeidTests/SelfProofTests.swift`'s `OwnerKeyProviderSelfProofTests`.
 * Per `docs/specs/barnard-binding-conformance.md` §5, a self-consistency
 * test here proves nothing; these assert against Barnard's independently
 * pinned output — the same literal values `test-vectors/owner-key-v1.txt`
 * pins and iOS's own tests already hardcode.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class OwnerKeyProviderTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val identity = BarnardIdentity(context)

    @Test
    fun publicKeyCompressedMatchesBarnardPinnedZeroSeedVector() {
        val provider = OwnerKeyProvider(
            identity = identity,
            keyStorage = FixedSeedOwnerKeyStorage(ByteArray(32)),
            randomSource = NeverCalledOwnerKeyRandomSource(),
        )

        assertEquals(
            "03351e5165d083f53425fc4a51e7228d53e88eb2899bcb6a83368a8aafaa1de5f4",
            provider.publicKeyCompressed().toLowercaseHex(),
        )
    }

    @Test
    fun publicKeyCompressedMatchesBarnardPinnedSequentialSeedVector() {
        val provider = OwnerKeyProvider(
            identity = identity,
            keyStorage = FixedSeedOwnerKeyStorage(sequentialSeed()),
            randomSource = NeverCalledOwnerKeyRandomSource(),
        )

        assertEquals(
            "03879beac8b548009124867a99a358aeb34ff42f957f868bbc83339568b16d9c67",
            provider.publicKeyCompressed().toLowercaseHex(),
        )
    }

    /**
     * `OwnerKeyProvider.signSelfProof`/`signWalletAcknowledgement` compose
     * `deriveOwnerKeyPair` (from the stored seed) with Barnard's signer —
     * that composed pair is beid's own device-generated key, not a value
     * Barnard's `test-vectors/owner-key-v1.txt` pins (its `selfproof_*`/
     * `walletack_*` groups use a fixed, arbitrary `ownerPrivateKey`
     * (`scalarOne`) as a direct primitive input, independent of
     * `deriveOwnerKeyPair`). Golden-vector conformance for the signing
     * primitives themselves is in [SelfProofMessageLayoutTest]. This
     * proves the *composition* is wired correctly instead: the same stored
     * seed's derived key actually signs, and a different self-proof input
     * (a different ENIN range) really does change the output.
     */
    @Test
    fun signSelfProofUsesTheStoredOwnerKeyAndVariesWithItsInputs() {
        val provider = OwnerKeyProvider(
            identity = identity,
            keyStorage = FixedSeedOwnerKeyStorage(sequentialSeed()),
            randomSource = NeverCalledOwnerKeyRandomSource(),
        )
        val eventIdHash = sequentialBytes(0x00, 32)
        val eventSigningPublicKey =
            "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5".hexToByteArray()

        val first = provider.signSelfProof(eventIdHash, eventSigningPublicKey, eninStart = 12, eninEnd = 34)
        val second = provider.signSelfProof(eventIdHash, eventSigningPublicKey, eninStart = 12, eninEnd = 35)

        assertNotNull(first)
        assertNotNull(second)
        assertTrue(
            !first.r.contentEquals(second.r) || !first.s.contentEquals(second.s),
            "a different eninEnd must sign different bytes",
        )
    }

    @Test
    fun signWalletAcknowledgementUsesTheStoredOwnerKeyAndVariesWithItsInputs() {
        val provider = OwnerKeyProvider(
            identity = identity,
            keyStorage = FixedSeedOwnerKeyStorage(sequentialSeed()),
            randomSource = NeverCalledOwnerKeyRandomSource(),
        )

        val first = provider.signWalletAcknowledgement(sequentialBytes(0x20, 20), sequentialBytes(0x40, 65))
        val second = provider.signWalletAcknowledgement(sequentialBytes(0x21, 20), sequentialBytes(0x40, 65))

        assertNotNull(first)
        assertNotNull(second)
        assertTrue(
            !first.r.contentEquals(second.r) || !first.s.contentEquals(second.s),
            "a different walletAddress must sign different bytes",
        )
    }

    @Test
    fun ownerKeyIsCachedAcrossCallsRatherThanRederivedEveryTime() {
        var callCount = 0
        val provider = OwnerKeyProvider(
            identity = identity,
            keyStorage = object : OwnerKeyStorage {
                private val seed = sequentialSeed()
                override fun bytes(key: String): ByteArray? {
                    callCount += 1
                    return seed
                }

                override fun putBytes(key: String, bytes: ByteArray) = Unit
            },
            randomSource = NeverCalledOwnerKeyRandomSource(),
        )

        provider.publicKeyCompressed()
        provider.publicKeyCompressed()

        assertEquals(1, callCount, "the stored seed must be read at most once, then cached")
    }

    @Test
    fun aMissingStoredSeedIsGeneratedAndPersisted() {
        var stored: ByteArray? = null
        val provider = OwnerKeyProvider(
            identity = identity,
            keyStorage = object : OwnerKeyStorage {
                override fun bytes(key: String): ByteArray? = stored
                override fun putBytes(key: String, bytes: ByteArray) {
                    stored = bytes
                }
            },
            randomSource = object : OwnerKeyRandomSource {
                override fun randomBytes(count: Int): ByteArray = sequentialBytes(0x01, count)
            },
        )

        val publicKey = provider.publicKeyCompressed()

        assertEquals(sequentialBytes(0x01, 32).toLowercaseHex(), stored?.toLowercaseHex())
        // Sanity: a generated seed still round-trips through deriveOwnerKeyPair.
        assertEquals(33, publicKey.size)
    }

    /**
     * A stored value of the wrong length must never reach
     * `BarnardIdentity.deriveOwnerKeyPair`, which throws
     * (`require(accountSecret.size == 32)`) rather than returning `null` —
     * unlike Barnard's other owner-key primitives. A first Android pass
     * regenerates silently rather than quarantining the bad value (gh#156's
     * quarantine/Signal-A mechanism is iOS-only for now; see handoff).
     */
    @Test
    fun aWrongLengthStoredSeedIsRegeneratedWithoutCrashing() {
        val provider = OwnerKeyProvider(
            identity = identity,
            keyStorage = FixedSeedOwnerKeyStorage(ByteArray(16)),
            randomSource = object : OwnerKeyRandomSource {
                override fun randomBytes(count: Int): ByteArray = sequentialBytes(0x02, count)
            },
        )

        val publicKey = provider.publicKeyCompressed()

        assertEquals(33, publicKey.size, "must not crash and must still produce a valid key")
    }
}

internal fun sequentialBytes(start: Int, count: Int): ByteArray =
    ByteArray(count) { index -> (start + index).toByte() }

internal fun sequentialSeed(): ByteArray = sequentialBytes(0x00, 32)

private class FixedSeedOwnerKeyStorage(private val seed: ByteArray) : OwnerKeyStorage {
    override fun bytes(key: String): ByteArray? = seed
    override fun putBytes(key: String, bytes: ByteArray) = Unit
}

private class NeverCalledOwnerKeyRandomSource : OwnerKeyRandomSource {
    override fun randomBytes(count: Int): ByteArray {
        throw AssertionError("randomSource must not be used when a seed is already stored")
    }
}

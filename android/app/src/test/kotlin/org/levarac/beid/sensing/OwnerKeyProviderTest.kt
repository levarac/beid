package org.levarac.beid.sensing

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.barnard.BarnardIdentity
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
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
                override fun readBytes(key: String): OwnerKeyReadResult {
                    callCount += 1
                    check(callCount == 1) { "storage unavailable after preflight" }
                    return OwnerKeyReadResult.Present(seed)
                }

                override fun putBytes(key: String, bytes: ByteArray) = Unit
            },
            randomSource = NeverCalledOwnerKeyRandomSource(),
        )

        provider.publicKeyCompressed()
        provider.publicKeyCompressed()
        assertNotNull(provider.signSelfProof(sequentialBytes(0x10, 32), "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5".hexToByteArray(), 10, 11))
        assertNotNull(provider.signWalletAcknowledgement(sequentialBytes(0x20, 20), sequentialBytes(0x40, 65)))

        assertEquals(1, callCount, "the stored seed must be read at most once, then cached")
    }

    @Test
    fun aMissingStoredSeedIsGeneratedAndPersisted() {
        var stored: ByteArray? = null
        val provider = OwnerKeyProvider(
            identity = identity,
            keyStorage = object : OwnerKeyStorage {
                override fun readBytes(key: String): OwnerKeyReadResult =
                    stored?.let(OwnerKeyReadResult::Present) ?: OwnerKeyReadResult.Missing
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

    /** A stored value of the wrong length must neither reach Barnard nor be replaced. */
    @Test
    fun aWrongLengthStoredSeedFailsWithoutRegeneratingOrOverwriting() {
        var putCalls = 0
        var randomCalls = 0
        val storage = object : OwnerKeyStorage {
            override fun readBytes(key: String): OwnerKeyReadResult =
                OwnerKeyReadResult.Present(ByteArray(16))

            override fun putBytes(key: String, bytes: ByteArray) {
                putCalls += 1
            }
        }
        val provider = OwnerKeyProvider(
            identity = identity,
            keyStorage = storage,
            randomSource = object : OwnerKeyRandomSource {
                override fun randomBytes(count: Int): ByteArray {
                    randomCalls += 1
                    return sequentialBytes(0x02, count)
                }
            },
        )

        val error = assertFailsWith<OwnerKeyUnavailableException> {
            provider.publicKeyCompressed()
        }

        assertEquals(OwnerKeyStorageFailure.CORRUPT, error.failure)
        assertEquals(0, randomCalls)
        assertEquals(0, putCalls)
    }

    @Test
    fun aCorruptStoredSeedFailsWithoutRegeneratingOrOverwriting() {
        assertReadFailureIsPreserved(OwnerKeyStorageFailure.CORRUPT)
    }

    @Test
    fun aTemporarilyUnavailableStoredSeedFailsWithoutRegeneratingOrOverwriting() {
        assertReadFailureIsPreserved(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE)
    }

    @Test
    fun aRestoreMismatchFailsWithoutRegeneratingOrOverwriting() {
        assertReadFailureIsPreserved(OwnerKeyStorageFailure.RESTORE_MISMATCH)
    }

    @Test
    fun aLegacyPlaintextSeedFailsWithoutMigrationDeletionOrRegeneration() {
        assertReadFailureIsPreserved(OwnerKeyStorageFailure.LEGACY_PLAINTEXT)
    }

    @Test
    fun firstGenerationMustReadBackTheExactPersistedSeedBeforeDeriving() {
        val storage = object : OwnerKeyStorage {
            var saved: ByteArray? = null
            override fun readBytes(key: String): OwnerKeyReadResult =
                saved?.let { OwnerKeyReadResult.Present(it.reversedArray()) } ?: OwnerKeyReadResult.Missing

            override fun putBytes(key: String, bytes: ByteArray) {
                saved = bytes.copyOf()
            }
        }
        val provider = OwnerKeyProvider(
            identity = identity,
            keyStorage = storage,
            randomSource = object : OwnerKeyRandomSource {
                override fun randomBytes(count: Int): ByteArray = sequentialBytes(0x02, count)
            },
        )

        val error = assertFailsWith<OwnerKeyUnavailableException> {
            provider.publicKeyCompressed()
        }

        assertEquals(OwnerKeyStorageFailure.WRITE_VERIFICATION_FAILED, error.failure)
    }

    @Test
    fun temporaryFailureCanBeRetriedWithoutGeneratingAReplacementIdentity() {
        var reads = 0
        var randomCalls = 0
        val provider = OwnerKeyProvider(
            identity = identity,
            keyStorage = object : OwnerKeyStorage {
                override fun readBytes(key: String): OwnerKeyReadResult {
                    reads += 1
                    return if (reads == 1) {
                        OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE)
                    } else {
                        OwnerKeyReadResult.Present(sequentialSeed())
                    }
                }

                override fun putBytes(key: String, bytes: ByteArray) = error("must not overwrite")
            },
            randomSource = object : OwnerKeyRandomSource {
                override fun randomBytes(count: Int): ByteArray {
                    randomCalls += 1
                    return ByteArray(count)
                }
            },
        )

        val first = assertFailsWith<OwnerKeyUnavailableException> { provider.publicKeyCompressed() }
        val recovered = provider.publicKeyCompressed()

        assertEquals(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE, first.failure)
        assertEquals(33, recovered.size)
        assertEquals(0, randomCalls)
    }

    private fun assertReadFailureIsPreserved(failure: OwnerKeyStorageFailure) {
        val storage = RecordingOwnerKeyStorage(OwnerKeyReadResult.Failure(failure))
        var randomCalls = 0
        val provider = OwnerKeyProvider(
            identity = identity,
            keyStorage = storage,
            randomSource = object : OwnerKeyRandomSource {
                override fun randomBytes(count: Int): ByteArray {
                    randomCalls += 1
                    return ByteArray(count)
                }
            },
        )

        val error = assertFailsWith<OwnerKeyUnavailableException> {
            provider.publicKeyCompressed()
        }

        assertEquals(failure, error.failure)
        assertEquals(0, randomCalls)
        assertEquals(0, storage.putCalls)
    }
}

internal fun sequentialBytes(start: Int, count: Int): ByteArray =
    ByteArray(count) { index -> (start + index).toByte() }

internal fun sequentialSeed(): ByteArray = sequentialBytes(0x00, 32)

private class FixedSeedOwnerKeyStorage(private val seed: ByteArray) : OwnerKeyStorage {
    override fun readBytes(key: String): OwnerKeyReadResult = OwnerKeyReadResult.Present(seed)
    override fun putBytes(key: String, bytes: ByteArray) = Unit
}

private class RecordingOwnerKeyStorage(
    private val result: OwnerKeyReadResult,
) : OwnerKeyStorage {
    var putCalls = 0
        private set

    override fun readBytes(key: String): OwnerKeyReadResult = result

    override fun putBytes(key: String, bytes: ByteArray) {
        putCalls += 1
    }
}

private class NeverCalledOwnerKeyRandomSource : OwnerKeyRandomSource {
    override fun randomBytes(count: Int): ByteArray {
        throw AssertionError("randomSource must not be used when a seed is already stored")
    }
}

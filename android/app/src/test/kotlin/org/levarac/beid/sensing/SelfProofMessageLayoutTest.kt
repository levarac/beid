package org.levarac.beid.sensing

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.barnard.BarnardIdentity
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/**
 * Golden-vector conformance for the self-proof message's 135-byte layout
 * against Barnard's own pinned offsets (`test-vectors/owner-key-v1.txt`'s
 * `selfproof_*` group, v0.5.0). Calls `BarnardIdentity.buildSelfProofMessage`
 * directly — Barnard's own function, not Android's re-derivation of the
 * same bytes — mirroring `ios/BeidTests/SelfProofTests.swift`'s
 * `SelfProofMessageLayoutTests`, which calls `BarnardCoreSigning
 * .buildSelfProofMessage` the same way.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SelfProofMessageLayoutTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val identity = BarnardIdentity(context)

    private val eventIdHash = sequentialBytes(0x00, 32)
    private val eventSigningPublicKey =
        "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5".hexToByteArray()
    private val ownerPublicKey =
        "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798".hexToByteArray()

    @Test
    fun selfProofMessageLayoutMatchesBarnardPinnedOffsets() {
        val message = assertNotNull(
            identity.buildSelfProofMessage(
                eventIdHash,
                eventSigningPublicKey,
                0x0102_0304_0506_0708uL,
                0x1112_1314_1516_1718uL,
                ownerPublicKey,
            ),
        )

        assertEquals(135, message.size)
        assertContentEquals("barnard-self-proof:v1".toByteArray(Charsets.UTF_8), message.copyOfRange(0, 21))
        assertContentEquals(eventIdHash, message.copyOfRange(21, 53))
        assertContentEquals(eventSigningPublicKey, message.copyOfRange(53, 86))
        assertContentEquals(
            "01020304050607081112131415161718".hexToByteArray(),
            message.copyOfRange(86, 102),
        )
        assertContentEquals(ownerPublicKey, message.copyOfRange(102, 135))
    }

    @Test
    fun walletAcknowledgementMessageLayoutMatchesBarnardPinnedOffsets() {
        val walletAddress = sequentialBytes(0x20, 20)
        val walletSignature = sequentialBytes(0x40, 65)

        val message = assertNotNull(identity.buildWalletAcknowledgementMessage(walletAddress, walletSignature))

        assertEquals(73, message.size, "domain tag (21) + walletAddress (20) + SHA256(walletSignature) (32)")
        assertContentEquals("barnard-wallet-ack:v1".toByteArray(Charsets.UTF_8), message.copyOfRange(0, 21))
        assertContentEquals(walletAddress, message.copyOfRange(21, 41))
    }

    /**
     * `test-vectors/owner-key-v1.txt`'s `selfproof_*` group pins
     * `ownerPrivateKey = scalarOne` (`0x00..0001`) and
     * `ownerPublicKey = generatorCompressed` directly as fixed inputs to
     * `signSelfProof` — independent of `deriveOwnerKeyPair` (no seed
     * derives this pair; it is chosen for simplicity in Barnard's own
     * suite). Calls `BarnardIdentity.signSelfProof` directly with those
     * exact literals, matching `ios/BeidTests/SelfProofTests.swift`'s
     * `OwnerKeyProviderSelfProofTests` inputs. Asserts the byte-exact
     * `(r, s, v)` the Swift reference pinned — stronger than a round-trip-
     * through-verify check, since it proves conformance even where Android
     * exposes no verifier (spec-133's own Non-goal).
     */
    @Test
    fun signSelfProofMatchesBarnardPinnedVector() {
        val ownerPrivateKey = "0".repeat(63) + "1"

        val signature = assertNotNull(
            identity.signSelfProof(
                ownerPrivateKey,
                eventIdHash,
                eventSigningPublicKey,
                12uL,
                34uL,
                ownerPublicKey,
            ),
        )

        assertEquals("61a5c17538920d8129030611976278ef32cd938b6ddff2c878a35f37a6b453ba", signature.r)
        assertEquals("28260168d623191d83fc9dfc160e984b8452573a1a0450226859f188cf23e6b1", signature.s)
        assertEquals(1, signature.v)
    }

    /** `test-vectors/owner-key-v1.txt`'s `walletack_*` group: same `scalarOne`/`generatorCompressed` pair as above. */
    @Test
    fun signWalletAcknowledgementMatchesBarnardPinnedVector() {
        val ownerPrivateKey = "0".repeat(63) + "1"
        val walletAddress = sequentialBytes(0x20, 20)
        val walletSignature = sequentialBytes(0x40, 65)

        val signature = assertNotNull(
            identity.signWalletAcknowledgement(ownerPrivateKey, walletAddress, walletSignature),
        )

        assertEquals("ff288f4744a3977c74c6b2743992115a460deb46ff6ad92e57ffc70257d017a9", signature.r)
        assertEquals("76e7b55c7505aab7e832a289fdf032825722ca745f9bf299d50418e6e3aaca67", signature.s)
        assertEquals(0, signature.v)
    }
}

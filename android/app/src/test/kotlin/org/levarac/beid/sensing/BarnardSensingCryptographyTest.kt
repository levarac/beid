package org.levarac.beid.sensing

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Wiring tests for [BarnardSensingCryptography] — the native facade
 * `EventJoinCoordinator` calls, mirroring iOS's
 * `ios/BeidTests/SensingCryptographyTests.swift` and AGENTS.md's framing of
 * this facade as a native testability boundary. The golden-vector
 * correctness of what it forwards to is already covered by
 * [OwnerKeyProviderTest]/[BindingMessageTest]; these tests only confirm the
 * facade actually forwards, not a second copy of the vector assertions.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class BarnardSensingCryptographyTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val cryptography = BarnardSensingCryptography(context)

    @Test
    fun ownerPublicKeyIsStableAcrossCalls() {
        val first = cryptography.ownerPublicKey()
        val second = cryptography.ownerPublicKey()

        assertEquals(33, first.size)
        assertTrue(first.contentEquals(second), "the owner key must not regenerate between calls")
    }

    @Test
    fun eventSigningPublicKeyIsStableForTheSameEventCodeAndDiffersForAnother() {
        val first = cryptography.eventSigningPublicKey("EVENT-A")
        val second = cryptography.eventSigningPublicKey("EVENT-A")
        val other = cryptography.eventSigningPublicKey("EVENT-B")

        assertEquals(33, first.size)
        assertTrue(first.contentEquals(second))
        assertTrue(!first.contentEquals(other))
    }

    @Test
    fun signSelfProofProducesASignatureDistinguishingItsEninRange() {
        val eventIdHash = EventIdHash.compute("FACADE-SELF-PROOF")
        val eventSigningPublicKey = cryptography.eventSigningPublicKey("FACADE-SELF-PROOF")

        val first = assertNotNull(
            cryptography.signSelfProof(eventIdHash, eventSigningPublicKey, eninStart = 1, eninEnd = 5),
        )
        val second = assertNotNull(
            cryptography.signSelfProof(eventIdHash, eventSigningPublicKey, eninStart = 1, eninEnd = 6),
        )

        assertTrue(!first.r.contentEquals(second.r) || !first.s.contentEquals(second.s), "a different ENIN range must sign different bytes")
    }

    @Test
    fun signWalletAcknowledgementForwardsItsInputs() {
        val walletAddress = sequentialBytes(0x20, 20)
        val walletSignature = sequentialBytes(0x40, 65)

        val signature = assertNotNull(cryptography.signWalletAcknowledgement(walletAddress, walletSignature))

        assertEquals(32, signature.r.size)
        assertEquals(32, signature.s.size)
    }

    @Test
    fun buildAccountBindingTextForwardsAllFieldsIntoBarnardsCanonicalBuilder() {
        val text = assertNotNull(
            cryptography.buildAccountBindingText(
                domain = BindingMessage.DOMAIN,
                walletAddress = sequentialBytes(0x14, 20),
                ownerPublicKey = cryptography.ownerPublicKey(),
                chainId = 1,
                nonce = sequentialBytes(0x00, 16),
                issuedAt = "2026-01-01T00:00:00Z",
            ),
        )

        assertTrue(text.startsWith(BindingMessage.DOMAIN))
    }
}

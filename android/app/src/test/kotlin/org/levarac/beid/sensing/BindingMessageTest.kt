package org.levarac.beid.sensing

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import java.time.Instant
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.barnard.BarnardIdentity
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Golden-vector conformance tests for [BindingMessage]
 * (`docs/specs/barnard-binding-conformance.md` §2.3, §5). The pinned
 * inputs/outputs are read directly from `levarac/barnard`'s own
 * `test-vectors/owner-key-v1.txt` (`binding_*` group, v0.5.0) — the same
 * literal values `ios/BeidTests/BindingMessageTests.swift` already
 * hardcodes. Asserts Android's type produces what Barnard's own suite
 * independently expects, not that Android's implementation is
 * self-consistent.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class BindingMessageTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val cryptography: SensingCryptography = BarnardSensingCryptography(context)

    private val pinnedWalletAddress = "14791697260e4c9a71f18484c9f997b308e59325".hexToByteArray()
    private val pinnedOwnerPublicKey =
        "03879beac8b548009124867a99a358aeb34ff42f957f868bbc83339568b16d9c67".hexToByteArray()
    private val pinnedNonce = "000102030405060708090a0b0c0d0e0f".hexToByteArray()
    private val pinnedIssuedAt = "2026-07-30T09:00:00Z"
    private val pinnedText = listOf(
        "beid.levarac.org wants to bind this wallet to a Levarac owner key.",
        "",
        "This signature authorizes no transaction and moves no assets.",
        "",
        "Domain-Tag: barnard-account-binding:v1",
        "Wallet: 0x14791697260e4c9a71f18484c9f997b308e59325",
        "Owner-Key: 0x03879beac8b548009124867a99a358aeb34ff42f957f868bbc83339568b16d9c67",
        "Chain-ID: eip155:1",
        "Scope: global",
        "Nonce: 0x000102030405060708090a0b0c0d0e0f",
        "Issued-At: 2026-07-30T09:00:00Z",
    ).joinToString("\n")

    private fun pinnedMessage() = BindingMessage(
        walletAddress = pinnedWalletAddress,
        ownerPublicKey = pinnedOwnerPublicKey,
        chainId = 1,
        nonce = pinnedNonce,
        issuedAt = pinnedIssuedAt,
    )

    @Test
    fun canonicalTextMatchesBarnardsPinnedGoldenVector() {
        val text = assertNotNull(pinnedMessage().canonicalText(cryptography))

        assertEquals(pinnedText, text)
        assertEquals(407, text.toByteArray(Charsets.UTF_8).size, "Barnard's own pinned vector is exactly 407 UTF-8 bytes")
        assertFalse(text.endsWith("\n"))
    }

    @Test
    fun walletMessageHexCarriesTextBytesNotADigest() {
        val messageHex = assertNotNull(pinnedMessage().walletMessageHex(cryptography))

        assertTrue(messageHex.startsWith("0x"))
        val decoded = messageHex.removePrefix("0x").hexToByteArray()
        assertEquals(407, decoded.size, "must carry the canonical text's raw UTF-8 bytes, not a 32-byte digest")
        assertEquals(pinnedText, String(decoded, Charsets.UTF_8))
    }

    @Test
    fun canonicalTextChangesWithNonceAndIssuedAt() {
        val a = pinnedMessage()
        val b = pinnedMessage().copy(nonce = "100102030405060708090a0b0c0d0e0f".hexToByteArray())
        val c = pinnedMessage().copy(issuedAt = "2026-07-30T09:00:01Z")

        assertNotEquals(a.canonicalText(cryptography), b.canonicalText(cryptography), "nonce must be covered by the signed text")
        assertNotEquals(a.canonicalText(cryptography), c.canonicalText(cryptography), "issuedAt must be covered by the signed text")
    }

    @Test
    fun canonicalTextRejectsWalletAddressOfTheWrongLength() {
        val message = pinnedMessage().copy(walletAddress = pinnedWalletAddress.copyOfRange(0, 19))

        assertNull(message.canonicalText(cryptography), "Barnard's own shape validation must reject a non-20-byte wallet address")
    }

    @Test
    fun canonicalIssuedAtFormatsSecondPrecisionUtc() {
        // 2026-07-30T09:00:00Z (Unix 1785402000), matching the golden vector's own Issued-At.
        val instant = Instant.ofEpochSecond(1_785_402_000)

        assertEquals(pinnedIssuedAt, BindingMessage.canonicalIssuedAt(instant))
    }
}

package org.levarac.parallax.registry

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals

class OpenEventCodeV1Test {
    @Test
    fun canonicalVectorUsesLowercaseHexTextBeforeHashing() {
        val eventId = ByteArray(32) { it.toByte() }
        val canonical = canonicalOpenCodeV1(eventId)
        val fullDigest = Sha256.digest(canonical.encodeToByteArray())

        assertEquals(
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
            canonical,
        )
        assertEquals(
            "6c86c6aac5fb24bcf5d9939cb7d7d5645ce39418f449e03b262dd4fa14b4b92b",
            fullDigest.toHexWithoutPrefixForOpenCodeTest(),
        )
        assertContentEquals(
            "6c86c6aac5fb24bc".decodeHex(),
            eventCodeHashForOpenEventV1(eventId),
        )
    }

    @Test
    fun noncanonicalTextAndRawBytesDoNotMatchTheCanonicalOpenCodeVector() {
        val eventId = ByteArray(32) { it.toByte() }
        val canonical = canonicalOpenCodeV1(eventId)

        assertNotEquals(canonical, canonical.uppercase())
        assertNotEquals(canonical, "0x$canonical")
        assertNotEquals(canonical, "$canonical ")
        assertNotEquals(canonical, canonical.drop(1))
        assertFalse(
            Sha256.digest(eventId).copyOfRange(0, 8)
                .contentEquals(eventCodeHashForOpenEventV1(eventId)),
        )
    }
}

private fun ByteArray.toHexWithoutPrefixForOpenCodeTest(): String = buildString(size * 2) {
    for (byte in this@toHexWithoutPrefixForOpenCodeTest) {
        val value = byte.toInt() and 0xff
        append("0123456789abcdef"[value ushr 4])
        append("0123456789abcdef"[value and 0x0f])
    }
}

package org.levarac.beid.sensing

import java.security.SecureRandom
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** beid#722 item 1: the CSPRNG port for Sigil presence tokens. */
class SigilPresenceTokenSourceTest {
    private class FixedRandom(private val bytes: ByteArray) : SecureRandom() {
        var requestedSizes = mutableListOf<Int>()
        override fun nextBytes(out: ByteArray) {
            requestedSizes += out.size
            bytes.copyInto(out, endIndex = out.size)
        }
    }

    private class FailingRandom : SecureRandom() {
        override fun nextBytes(out: ByteArray): Unit = throw IllegalStateException("entropy unavailable")
    }

    @Test
    fun sixteenRandomBytesBecomeThirtyTwoLowercaseHexCharacters() {
        val random = FixedRandom(ByteArray(16) { (0xf0 + it).toByte() })
        val token = SecureRandomSigilPresenceTokenSource(random).nextToken()
        assertEquals(listOf(16), random.requestedSizes)
        assertEquals("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff", token)
    }

    @Test
    fun leadingZeroBytesKeepTheirTwoDigits() {
        val token = SecureRandomSigilPresenceTokenSource(FixedRandom(ByteArray(16) { it.toByte() })).nextToken()
        assertEquals("000102030405060708090a0b0c0d0e0f", token)
    }

    @Test
    fun aFailedDrawIsNullNotAZeroToken() {
        assertNull(SecureRandomSigilPresenceTokenSource(FailingRandom()).nextToken())
    }

    @Test
    fun theDefaultSourceDrawsDistinctWellFormedTokens() {
        val source = SecureRandomSigilPresenceTokenSource()
        val first = assertNotNull(source.nextToken())
        val second = assertNotNull(source.nextToken())
        listOf(first, second).forEach { token ->
            assertEquals(32, token.length)
            assertTrue(token.all { it in '0'..'9' || it in 'a'..'f' }, token)
        }
        assertNotEquals(first, second)
    }
}

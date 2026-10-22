package org.levarac.beid.venue

import java.io.ByteArrayInputStream
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull

class BoundedVenueBundleReadTest {
    @Test
    fun bodyExactlyAtLimitIsAccepted() {
        val body = ByteArray(16) { it.toByte() }

        assertContentEquals(body, readBoundedVenueBundle(ByteArrayInputStream(body), 16))
    }

    @Test
    fun bodyOneByteOverLimitIsRejected() {
        val body = ByteArray(17) { it.toByte() }

        assertNull(readBoundedVenueBundle(ByteArrayInputStream(body), 16))
    }

    @Test
    fun oversizedBodyReadsOnlyOneByteBeyondLimit() {
        val input = ByteArrayInputStream(ByteArray(32))

        assertNull(readBoundedVenueBundle(input, 16))
        assertEquals(15, input.available())
    }

    @Test
    fun shortReadsContinueUntilTheWholeBodyIsRead() {
        val body = ByteArray(15) { it.toByte() }
        val input = object : ByteArrayInputStream(body) {
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
                super.read(buffer, offset, minOf(length, 3))
        }

        assertContentEquals(body, readBoundedVenueBundle(input, 16))
    }

    @Test
    fun emptyBodyIsAcceptedAsEmptyBytes() {
        assertContentEquals(byteArrayOf(), readBoundedVenueBundle(ByteArrayInputStream(byteArrayOf()), 16))
    }
}

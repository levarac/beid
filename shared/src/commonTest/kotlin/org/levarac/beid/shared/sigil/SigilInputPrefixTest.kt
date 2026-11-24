package org.levarac.beid.shared.sigil

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNotSame
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SigilInputPrefixTest {
    private fun input(windows: Int, vararg rows: Triple<String, Int, Int>): SigilInput =
        createSigilInput(windows).also { value ->
            rows.forEach { (peer, window, presence) ->
                assertTrue(addSigilPresence(value, peer, window, presence))
            }
        }

    private fun vector(): SigilInput = input(
        4,
        Triple("peer-a", 0, 1), Triple("peer-a", 1, 1),
        Triple("peer-b", 2, 1), Triple("peer-a", 3, 1), Triple("peer-c", 3, 2),
    )

    private data class Drawing(
        val counts: List<Int>,
        val peers: List<List<Any>>,
        val marks: List<List<Any>>,
    )

    private fun drawing(input: SigilInput): Drawing {
        val layout = layoutSigil(input, 200.0, SigilGround.DISC)
        assertTrue(layout.isSuccess)
        return Drawing(
            listOf(layout.windowCount, layout.ringCount, layout.detectedPeerCount, layout.mutualPeerCount),
            (0 until layout.peerCount).map { index ->
                val peer = assertNotNull(layout.peerAt(index))
                listOf(peer.peerKey, peer.baseAngleDegrees, peer.angleDegrees)
            },
            (0 until layout.primitiveCount).map { index ->
                val mark = assertNotNull(layout.primitiveAt(index))
                listOf(mark.kind, mark.x, mark.y, mark.x2, mark.y2, mark.radius, mark.lineWidth)
            },
        )
    }

    @Test
    fun literalPrefixesExcludeFuturePeersAndFutureMutuality() {
        val source = vector()
        val one = assertNotNull(sigilInputPrefixOrNull(source, 1))
        val two = assertNotNull(sigilInputPrefixOrNull(source, 2))
        assertEquals(drawing(input(1, Triple("peer-a", 0, 1))), drawing(one))
        assertEquals(drawing(input(2, Triple("peer-a", 0, 1), Triple("peer-a", 1, 1))), drawing(two))
        assertEquals(listOf(2, 2, 1, 0), drawing(two).counts)
        assertEquals(setOf("peer-a", "peer-b", "peer-c"), two.peers.keys)
    }

    @Test
    fun fullLengthAndShortPrefixesAreIndependentCopies() {
        val source = vector()
        val before = drawing(source)
        val full = assertNotNull(sigilInputPrefixOrNull(source, 4))
        val first = assertNotNull(sigilInputPrefixOrNull(source, 2))
        val second = assertNotNull(sigilInputPrefixOrNull(source, 2))
        val secondBefore = drawing(second)
        assertNotSame(source, full)
        assertNotSame(first, second)
        assertEquals(before, drawing(full))
        assertTrue(addSigilPresence(first, "peer-a", 1, 2))
        assertTrue(addSigilPresence(full, "another-peer", 0, 1))
        assertEquals(before, drawing(source))
        assertEquals(secondBefore, drawing(second))
    }

    @Test
    fun invalidCountsFailWithoutClampingOrMutation() {
        val source = vector()
        val before = drawing(source)
        listOf(Int.MIN_VALUE, -1, 0, 5, Int.MAX_VALUE).forEach { count ->
            assertNull(sigilInputPrefixOrNull(source, count))
            assertEquals(before, drawing(source))
        }
        listOf(-1, 0, 100_001, Int.MAX_VALUE).forEach { windows ->
            assertNull(sigilInputPrefixOrNull(createSigilInput(windows), 1))
        }
        assertNotNull(sigilInputPrefixOrNull(createSigilInput(100_000), 100_000))
    }

    @Test
    fun validEmptyInputRetainsMeasuredZeroRatherThanFailing() {
        val prefix = assertNotNull(sigilInputPrefixOrNull(createSigilInput(4), 2))
        assertEquals(drawing(createSigilInput(2)), drawing(prefix))
        assertEquals(listOf(2, 2, 0, 0), drawing(prefix).counts)
    }

    @Test
    fun malformedFutureEntriesAreRejectedBeforeCropping() {
        listOf(-1, 4).forEach { window ->
            val source = vector()
            source.peers.getValue("peer-a").presenceByWindow[window] = 1
            assertNull(sigilInputPrefixOrNull(source, 1))
            assertEquals(1, source.peers.getValue("peer-a").presenceByWindow[window])
        }
        listOf(0, 3).forEach { presence ->
            val source = vector()
            source.peers.getValue("peer-a").presenceByWindow[3] = presence
            assertNull(sigilInputPrefixOrNull(source, 1))
            assertEquals(presence, source.peers.getValue("peer-a").presenceByWindow[3])
        }
        val badKey = vector()
        badKey.peers[""] = SigilPeerEntries()
        assertNull(sigilInputPrefixOrNull(badKey, 1))
    }

    @Test
    fun malformedCapacityFailsWithoutReturningAPartialPrefix() {
        val peers = createSigilInput(2)
        repeat(1_025) { peers.peers["peer-$it"] = SigilPeerEntries() }
        assertNull(sigilInputPrefixOrNull(peers, 1))
        val entries = createSigilInput(100_000)
        val first = SigilPeerEntries()
        repeat(100_000) { first.presenceByWindow[it] = 1 }
        entries.peers["first"] = first
        entries.peers["second"] = SigilPeerEntries(hashMapOf(99_999 to 1))
        assertNull(sigilInputPrefixOrNull(entries, 1))
    }

    @Test
    fun shuffledAndDuplicateInputsKeepTheSamePeerAndPrimitiveOrder() {
        val shuffled = input(
            4,
            Triple("peer-c", 3, 2), Triple("peer-a", 3, 1), Triple("peer-b", 2, 1),
            Triple("peer-a", 1, 1), Triple("peer-a", 0, 1), Triple("peer-a", 0, 1),
        )
        assertEquals(
            drawing(assertNotNull(sigilInputPrefixOrNull(vector(), 2))),
            drawing(assertNotNull(sigilInputPrefixOrNull(shuffled, 2))),
        )
    }

    @Test
    fun prefixUsesExistingRingBinningWithoutFreezingFullSessionGeometry() {
        val source = createSigilInput(13)
        repeat(13) { assertTrue(addSigilPresence(source, "peer", it, 1)) }
        val before = drawing(source)
        val twelve = assertNotNull(sigilInputPrefixOrNull(source, 12))
        val thirteen = assertNotNull(sigilInputPrefixOrNull(source, 13))
        assertEquals(12, layoutSigil(twelve, 200.0, SigilGround.DISC).ringCount)
        assertEquals(7, layoutSigil(thirteen, 200.0, SigilGround.DISC).ringCount)
        assertEquals(before, drawing(source))
    }
}

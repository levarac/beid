package org.levarac.beid.shared.sigil

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.levarac.beid.shared.aggregation.AggregationObservationInput
import org.levarac.beid.shared.aggregation.addAggregationObservation
import org.levarac.beid.shared.aggregation.aggregateObservationsForSession
import org.levarac.beid.shared.aggregation.createAggregationObservationInput

/**
 * Vectors for the shared Sigil presence family (beid#653,
 * docs/decisions/issue-653-design.md sections 1-3 and 7).
 *
 * Every cap, length and expected text below is a LITERAL, never a production
 * constant cited by reference: a vector that reads the constant it guards
 * moves with that constant and cannot go red when it regresses
 * (scripts/mutation_check.py, AGENTS.md).
 */
class SigilPresenceTest {

    private val tokenA = "ffffffffffffffffffffffffffffffff"
    private val tokenB = "00000000000000000000000000000001"
    private val tokenC = "0123456789abcdef0123456789abcdef"

    private fun token(n: Int): String = n.toString(16).padStart(32, '0')

    private fun observations(vararg rows: Triple<Long, String, String?>): AggregationObservationInput {
        val input = createAggregationObservationInput()
        rows.forEach { (window, rpid, displayId) ->
            assertTrue(addAggregationObservation(input, window, rpid, displayId, false))
        }
        return input
    }

    private fun fillTokens(session: SigilPresenceSession, input: AggregationObservationInput, first: Int = 1) {
        val needed = sigilPresenceTokensNeeded(session, input)
        for (i in 0 until needed) {
            assertTrue(addSigilPresenceToken(session, input, token(first + i)), "token ${first + i}")
        }
    }

    private fun encoded(session: SigilPresenceSession, input: AggregationObservationInput): String {
        val result = encodeSigilPresenceSnapshot(session, input)
        assertTrue(result.isSuccess, "encode failed: ${result.errorCode}")
        assertNull(result.errorCode)
        return assertNotNull(result.snapshotText)
    }

    private fun assertDecodeRejected(text: String, code: String) {
        val loaded = decodeSigilPresenceSnapshot(text)
        assertFalse(loaded.isSuccess, "accepted: $text")
        assertEquals(code, loaded.errorCode, "for: $text")
        assertNull(loaded.input)
    }

    // A canonical two-peer, two-window text. tokenB sorts before tokenA.
    private val twoPeerText =
        "beid-sigil-presence\t1\n" +
            "windows\t2\n" +
            "peers\t2\n" +
            "peer\t00000000000000000000000000000001\t1\n" +
            "peer\tffffffffffffffffffffffffffffffff\t0,1\n" +
            "end\n"

    // MARK: - Token assignment

    @Test
    fun tokensAreTheSuppliedValuesAssignedInFirstSeenOrder() {
        val input = observations(
            Triple(10L, "rpid-a", "aaaa0001"),
            Triple(10L, "rpid-b", null),
            Triple(11L, "rpid-c", "bbbb0002"),
            Triple(11L, "rpid-d", "aaaa0001"),
        )
        val session = createSigilPresenceSession()
        assertEquals(2, sigilPresenceTokensNeeded(session, input))
        assertTrue(addSigilPresenceToken(session, input, tokenA))
        assertEquals(1, sigilPresenceTokensNeeded(session, input))
        assertTrue(addSigilPresenceToken(session, input, tokenB))
        assertEquals(0, sigilPresenceTokensNeeded(session, input))
        assertFalse(addSigilPresenceToken(session, input, tokenC), "nothing is awaiting a token")

        // aaaa0001 was seen first, so it holds tokenA; it is present in both
        // windows. bbbb0002 holds tokenB and is present in the second window.
        assertEquals(twoPeerText, encoded(session, input))
    }

    @Test
    fun theStoredTextCarriesNoDisplayIdRpidOrEnin() {
        val input = observations(
            Triple(777001L, "rpid-zz", "c0ffee01"),
            Triple(777002L, "rpid-yy", "c0ffee01"),
        )
        val session = createSigilPresenceSession()
        assertTrue(addSigilPresenceToken(session, input, tokenC))
        val text = encoded(session, input)
        assertEquals(
            "beid-sigil-presence\t1\nwindows\t2\npeers\t1\n" +
                "peer\t0123456789abcdef0123456789abcdef\t0,1\nend\n",
            text,
        )
        assertFalse(text.contains("c0ffee01"))
        assertFalse(text.contains("rpid"))
        assertFalse(text.contains("777"))
    }

    @Test
    fun theSameDisplayIdsInTwoSessionsGetUnrelatedTokens() {
        val rows = arrayOf(Triple(5L, "rpid-1", "d1d1d1d1"), Triple(6L, "rpid-2", "d2d2d2d2"))
        val first = observations(*rows)
        val second = observations(*rows)
        val sessionOne = createSigilPresenceSession()
        val sessionTwo = createSigilPresenceSession()
        fillTokens(sessionOne, first, first = 1)
        fillTokens(sessionTwo, second, first = 100)
        val one = encoded(sessionOne, first)
        val two = encoded(sessionTwo, second)
        assertEquals(
            "beid-sigil-presence\t1\nwindows\t2\npeers\t2\n" +
                "peer\t00000000000000000000000000000001\t0\n" +
                "peer\t00000000000000000000000000000002\t1\nend\n",
            one,
        )
        assertEquals(
            "beid-sigil-presence\t1\nwindows\t2\npeers\t2\n" +
                "peer\t00000000000000000000000000000064\t0\n" +
                "peer\t00000000000000000000000000000065\t1\nend\n",
            two,
        )
    }

    @Test
    fun tokenShapeIsExactlyThirtyTwoLowercaseHexCharacters() {
        val input = observations(Triple(1L, "r", "d0000001"))
        fun accepts(candidate: String): Boolean =
            addSigilPresenceToken(createSigilPresenceSession(), input, candidate)
        assertTrue(accepts("0123456789abcdef0123456789abcdef"))
        assertTrue(accepts("abcdefabcdefabcdefabcdefabcdefab"))
        assertFalse(accepts("0123456789abcdef0123456789abcde"), "31 characters")
        assertFalse(accepts("0123456789abcdef0123456789abcdef0"), "33 characters")
        assertFalse(accepts("0123456789ABCDEF0123456789ABCDEF"), "uppercase")
        assertFalse(accepts("0123456789abcdef0123456789abcdeg"), "non-hex")
        assertFalse(accepts("0123456789abcdef 123456789abcdef"), "space")
        assertFalse(accepts(""), "empty")
    }

    @Test
    fun aRejectedTokenShapeAssignsNothing() {
        val input = observations(Triple(1L, "r", "d0000001"))
        val session = createSigilPresenceSession()
        assertFalse(addSigilPresenceToken(session, input, "short"))
        assertEquals(1, sigilPresenceTokensNeeded(session, input))
        assertTrue(addSigilPresenceToken(session, input, tokenC))
        assertEquals(0, sigilPresenceTokensNeeded(session, input))
    }

    @Test
    fun aDuplicateTokenFailsTheWholeSessionPermanently() {
        val input = observations(
            Triple(1L, "r1", "d0000001"),
            Triple(1L, "r2", "d0000002"),
            Triple(1L, "r3", "d0000003"),
        )
        val session = createSigilPresenceSession()
        val zeros = "00000000000000000000000000000000"
        assertTrue(addSigilPresenceToken(session, input, zeros))
        assertFalse(addSigilPresenceToken(session, input, zeros), "an all-zero source repeats itself")
        assertEquals(0, sigilPresenceTokensNeeded(session, input))
        assertFalse(addSigilPresenceToken(session, input, tokenA), "a later good token cannot repair it")
        val result = encodeSigilPresenceSnapshot(session, input)
        assertFalse(result.isSuccess)
        assertEquals("duplicate_token", result.errorCode)
        assertNull(result.snapshotText)
        val live = buildSigilPresenceInput(session, input)
        assertFalse(live.isSuccess)
        assertEquals("duplicate_token", live.errorCode)
        assertNull(live.input)
    }

    @Test
    fun aMissingTokenFailsUntilItIsToppedUp() {
        val input = observations(Triple(1L, "r1", "d0000001"), Triple(2L, "r2", "d0000002"))
        val session = createSigilPresenceSession()
        assertTrue(addSigilPresenceToken(session, input, tokenA))
        val early = encodeSigilPresenceSnapshot(session, input)
        assertFalse(early.isSuccess)
        assertEquals("missing_token", early.errorCode)
        assertEquals("missing_token", buildSigilPresenceInput(session, input).errorCode)
        assertTrue(addSigilPresenceToken(session, input, tokenB))
        assertTrue(encodeSigilPresenceSnapshot(session, input).isSuccess)
    }

    @Test
    fun observationsAddedAfterATopUpAreScannedIncrementally() {
        val input = observations(Triple(1L, "r1", "d0000001"))
        val session = createSigilPresenceSession()
        fillTokens(session, input, first = 1)
        assertTrue(addAggregationObservation(input, 2L, "r2", "d0000002", false))
        assertTrue(addAggregationObservation(input, 2L, "r3", "d0000001", false))
        assertEquals(1, sigilPresenceTokensNeeded(session, input))
        fillTokens(session, input, first = 2)
        assertEquals(
            "beid-sigil-presence\t1\nwindows\t2\npeers\t2\n" +
                "peer\t00000000000000000000000000000001\t0,1\n" +
                "peer\t00000000000000000000000000000002\t1\nend\n",
            encoded(session, input),
        )
    }

    @Test
    fun aSessionIsBoundToTheFirstInputItSees() {
        val first = observations(Triple(1L, "r1", "d0000001"))
        val other = observations(Triple(1L, "r1", "d0000001"))
        val session = createSigilPresenceSession()
        assertEquals(1, sigilPresenceTokensNeeded(session, first))
        assertEquals(0, sigilPresenceTokensNeeded(session, other))
        assertFalse(addSigilPresenceToken(session, other, tokenA))
        assertEquals("input_mismatch", encodeSigilPresenceSnapshot(session, other).errorCode)
        assertEquals("input_mismatch", buildSigilPresenceInput(session, other).errorCode)
        // The mismatch changed nothing for the bound input.
        assertTrue(addSigilPresenceToken(session, first, tokenA))
        assertTrue(encodeSigilPresenceSnapshot(session, first).isSuccess)
    }

    @Test
    fun anEmptyInputHasNoWindows() {
        val input = createAggregationObservationInput()
        val session = createSigilPresenceSession()
        assertEquals(0, sigilPresenceTokensNeeded(session, input))
        assertEquals("no_windows", encodeSigilPresenceSnapshot(session, input).errorCode)
        assertEquals("no_windows", buildSigilPresenceInput(session, input).errorCode)
    }

    // MARK: - Window axis and peer set

    @Test
    fun windowsAreRanksOverObservedEninsIncludingDisplayIdLessOnes() {
        // ENINs 1000, 1005 and 1002 rank 0, 2 and 1. ENIN 1009 holds only a
        // display-id-less observation: it is a window (W = 4) with no peer.
        val input = observations(
            Triple(1005L, "r1", "d0000001"),
            Triple(1000L, "r2", "d0000001"),
            Triple(1002L, "r3", "d0000002"),
            Triple(1009L, "r4", null),
        )
        val session = createSigilPresenceSession()
        fillTokens(session, input, first = 1)
        assertEquals(
            "beid-sigil-presence\t1\nwindows\t4\npeers\t2\n" +
                "peer\t00000000000000000000000000000001\t0,2\n" +
                "peer\t00000000000000000000000000000002\t1\nend\n",
            encoded(session, input),
        )
    }

    @Test
    fun peerAndWindowCountsMatchTheSessionAggregateOfTheSameInput() {
        val input = createAggregationObservationInput()
        for (window in 0 until 9) {
            for (peer in 0 until 7) {
                if ((window + peer) % 3 == 0) continue
                val displayId = if (peer == 6) null else "d000000$peer"
                assertTrue(addAggregationObservation(input, 500L + window * 2, "r$window-$peer", displayId, false))
            }
        }
        val session = createSigilPresenceSession()
        fillTokens(session, input)
        val aggregate = aggregateObservationsForSession(input, 1)
        val live = buildSigilPresenceInput(session, input)
        assertTrue(live.isSuccess)
        val layout = layoutSigil(assertNotNull(live.input), 200.0, SigilGround.NONE)
        assertEquals(6, aggregate.deviceCount)
        assertEquals(9, aggregate.windowCount)
        assertEquals(6, layout.peerCount)
        assertEquals(6, layout.detectedPeerCount)
        assertEquals(9, layout.windowCount)
    }

    @Test
    fun presenceIsNeverMutual() {
        val input = observations(
            Triple(1L, "r1", "d0000001"),
            Triple(2L, "r2", "d0000001"),
            Triple(2L, "r3", "d0000002"),
        )
        val session = createSigilPresenceSession()
        fillTokens(session, input)
        for (source in listOf(
            assertNotNull(buildSigilPresenceInput(session, input).input),
            assertNotNull(decodeSigilPresenceSnapshot(encoded(session, input)).input),
        )) {
            for (size in listOf(60.0, 200.0)) {
                val layout = layoutSigil(source, size, SigilGround.NONE)
                assertTrue(layout.isSuccess)
                assertEquals(0, layout.mutualPeerCount)
                assertEquals(2, layout.detectedPeerCount)
                assertEquals(2, layout.windowCount)
                (0 until layout.primitiveCount).forEach { index ->
                    val kind = assertNotNull(layout.primitiveAt(index)).kind
                    assertTrue(kind != SigilPrimitiveKind.MUTUAL_DOT && kind != SigilPrimitiveKind.MUTUAL_LINE, "$kind")
                }
            }
        }
    }

    @Test
    fun theLiveInputAndTheDecodedSnapshotLayOutIdentically() {
        val input = createAggregationObservationInput()
        for (window in 0 until 14) {
            for (peer in 0 until 5) {
                if ((window * peer) % 4 == 1) continue
                assertTrue(addAggregationObservation(input, 40L + window, "r$window-$peer", "e000000$peer", false))
            }
        }
        val session = createSigilPresenceSession()
        fillTokens(session, input, first = 77)
        val live = assertNotNull(buildSigilPresenceInput(session, input).input)
        val decoded = assertNotNull(decodeSigilPresenceSnapshot(encoded(session, input)).input)
        for (size in listOf(48.0, 60.0, 84.0, 200.0, 290.0, 300.0)) {
            val a = layoutSigil(live, size, SigilGround.DISC)
            val b = layoutSigil(decoded, size, SigilGround.DISC)
            assertEquals(a.primitiveCount, b.primitiveCount)
            assertEquals(a.peerCount, b.peerCount)
            assertEquals(a.windowCount, b.windowCount)
            (0 until a.peerCount).forEach { i ->
                assertEquals(assertNotNull(a.peerAt(i)).peerKey, assertNotNull(b.peerAt(i)).peerKey)
                assertEquals(assertNotNull(a.peerAt(i)).angleDegrees, assertNotNull(b.peerAt(i)).angleDegrees)
            }
        }
    }

    // MARK: - Caps (literal)

    @Test
    fun oneThousandTwentyFourPeersAreAccepted() {
        val input = createAggregationObservationInput()
        for (i in 0 until 1024) {
            assertTrue(addAggregationObservation(input, 1L, "r$i", "p$i", false))
        }
        val session = createSigilPresenceSession()
        assertEquals(1024, sigilPresenceTokensNeeded(session, input))
        fillTokens(session, input)
        val text = encoded(session, input)
        assertTrue(text.startsWith("beid-sigil-presence\t1\nwindows\t1\npeers\t1024\n"))
        assertTrue(decodeSigilPresenceSnapshot(text).isSuccess)
    }

    @Test
    fun oneThousandTwentyFivePeersWriteNothing() {
        val input = createAggregationObservationInput()
        for (i in 0 until 1025) {
            assertTrue(addAggregationObservation(input, 1L, "r$i", "p$i", false))
        }
        val session = createSigilPresenceSession()
        assertEquals(0, sigilPresenceTokensNeeded(session, input))
        val result = encodeSigilPresenceSnapshot(session, input)
        assertFalse(result.isSuccess)
        assertEquals("too_many_peers", result.errorCode)
        assertNull(result.snapshotText)
        assertEquals("too_many_peers", buildSigilPresenceInput(session, input).errorCode)
    }

    @Test
    fun theThousandTwentyFifthPeerArrivingLaterAlsoWritesNothing() {
        val input = createAggregationObservationInput()
        for (i in 0 until 1024) {
            assertTrue(addAggregationObservation(input, 1L, "r$i", "p$i", false))
        }
        val session = createSigilPresenceSession()
        fillTokens(session, input)
        assertTrue(encodeSigilPresenceSnapshot(session, input).isSuccess)
        assertTrue(addAggregationObservation(input, 2L, "late", "p1024", false))
        assertEquals(0, sigilPresenceTokensNeeded(session, input))
        assertFalse(addSigilPresenceToken(session, input, tokenA))
        assertEquals("too_many_peers", encodeSigilPresenceSnapshot(session, input).errorCode)
    }

    @Test
    fun aRepeatedDisplayIdBeyondTheCapIsNotANewPeer() {
        val input = createAggregationObservationInput()
        for (i in 0 until 1024) {
            assertTrue(addAggregationObservation(input, 1L, "r$i", "p$i", false))
        }
        assertTrue(addAggregationObservation(input, 2L, "again", "p0", false))
        val session = createSigilPresenceSession()
        fillTokens(session, input)
        assertTrue(encodeSigilPresenceSnapshot(session, input).isSuccess)
    }

    @Test
    fun oneHundredThousandWindowsAreAccepted() {
        // The aggregation cap allows at most 100,000 observations, so 100,000
        // distinct windows is the largest W a real session can reach. It must
        // encode; the builder's own window guard must not fire at the cap.
        val input = createAggregationObservationInput()
        for (window in 0L until 100000L) {
            assertTrue(addAggregationObservation(input, window, "r$window", null, false))
        }
        val session = createSigilPresenceSession()
        assertEquals(0, sigilPresenceTokensNeeded(session, input))
        assertEquals("beid-sigil-presence\t1\nwindows\t100000\npeers\t0\nend\n", encoded(session, input))
        assertTrue(buildSigilPresenceInput(session, input).isSuccess)
    }

    // MARK: - Decoding

    @Test
    fun aCanonicalTextRoundTrips() {
        val loaded = decodeSigilPresenceSnapshot(twoPeerText)
        assertTrue(loaded.isSuccess)
        assertNull(loaded.errorCode)
        val input = assertNotNull(loaded.input)
        assertEquals(2, input.windowCount)
        val layout = layoutSigil(input, 200.0, SigilGround.NONE)
        assertEquals(
            listOf("00000000000000000000000000000001", "ffffffffffffffffffffffffffffffff"),
            (0 until layout.peerCount).map { assertNotNull(layout.peerAt(it)).peerKey }.sorted(),
        )
        assertEquals(2, layout.detectedPeerCount)
        assertEquals(0, layout.mutualPeerCount)
    }

    @Test
    fun aZeroPeerTextIsData() {
        val loaded = decodeSigilPresenceSnapshot("beid-sigil-presence\t1\nwindows\t3\npeers\t0\nend\n")
        assertTrue(loaded.isSuccess)
        val layout = layoutSigil(assertNotNull(loaded.input), 200.0, SigilGround.NONE)
        assertEquals(0, layout.peerCount)
        assertEquals(3, layout.windowCount)
    }

    @Test
    fun nonCanonicalAndMalformedTextsAreRejected() {
        val head = "beid-sigil-presence\t1\n"
        val t1 = "00000000000000000000000000000001"
        val t2 = "00000000000000000000000000000002"
        assertDecodeRejected(twoPeerText.replace("windows\t2", "windows\t02"), "noncanonical_snapshot")
        assertDecodeRejected(twoPeerText.replace("windows\t2", "windows\t+2"), "invalid_snapshot")
        assertDecodeRejected(twoPeerText.replace("\t0,1\n", "\t00,1\n"), "noncanonical_snapshot")
        assertDecodeRejected(head.replace("\t1", "\t2") + twoPeerText.removePrefix(head), "invalid_snapshot")
        assertDecodeRejected(twoPeerText.replace("\n", "\r\n"), "invalid_snapshot")
        assertDecodeRejected(twoPeerText.removeSuffix("\n"), "invalid_snapshot")
        assertDecodeRejected(twoPeerText + "extra\n", "invalid_snapshot")
        assertDecodeRejected(twoPeerText.replace("end\n", ""), "invalid_snapshot")
        assertDecodeRejected(twoPeerText.replace("peers\t2", "peers\t3"), "invalid_snapshot")
        assertDecodeRejected(twoPeerText.replace("peers\t2", "peers\t1"), "invalid_snapshot")
        // A presence column does not exist in v1.
        assertDecodeRejected(twoPeerText.replace("\t0,1\n", "\t0,1\t2\n"), "invalid_snapshot")
        assertDecodeRejected(twoPeerText.replace("\tffffffffffffffffffffffffffffffff\t", "\tFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF\t"), "invalid_snapshot")
        assertDecodeRejected(twoPeerText.replace("\t0,1\n", "\t\n"), "invalid_snapshot")
        assertDecodeRejected(twoPeerText.replace("\t0,1\n", "\t1,0\n"), "invalid_snapshot")
        assertDecodeRejected(twoPeerText.replace("\t0,1\n", "\t1,1\n"), "invalid_snapshot")
        assertDecodeRejected(twoPeerText.replace("\t0,1\n", "\t0,2\n"), "invalid_snapshot")
        assertDecodeRejected(twoPeerText.replace("\t0,1\n", "\t-1,1\n"), "invalid_snapshot")
        assertDecodeRejected(twoPeerText.replace("peer\t", "node\t"), "invalid_snapshot")
        // Tokens must be strictly ascending: unsorted and duplicated both fail.
        assertDecodeRejected("${head}windows\t1\npeers\t2\npeer\t$t2\t0\npeer\t$t1\t0\nend\n", "invalid_snapshot")
        assertDecodeRejected("${head}windows\t1\npeers\t2\npeer\t$t1\t0\npeer\t$t1\t0\nend\n", "invalid_snapshot")
        assertDecodeRejected("", "invalid_snapshot")
    }

    @Test
    fun theWindowCountBoundsAreLiteral() {
        val head = "beid-sigil-presence\t1\n"
        assertDecodeRejected("${head}windows\t0\npeers\t0\nend\n", "invalid_snapshot")
        assertTrue(decodeSigilPresenceSnapshot("${head}windows\t1\npeers\t0\nend\n").isSuccess)
        assertTrue(decodeSigilPresenceSnapshot("${head}windows\t100000\npeers\t0\nend\n").isSuccess)
        assertDecodeRejected("${head}windows\t100001\npeers\t0\nend\n", "invalid_snapshot")
    }

    @Test
    fun thePeerCountBoundIsLiteral() {
        val head = "beid-sigil-presence\t1\nwindows\t1\n"
        fun text(peers: Int): String = buildString {
            append(head).append("peers\t").append(peers).append('\n')
            for (i in 0 until peers) append("peer\t").append(token(i)).append("\t0\n")
            append("end\n")
        }
        assertTrue(decodeSigilPresenceSnapshot(text(1024)).isSuccess)
        assertDecodeRejected(text(1025), "invalid_snapshot")
    }

    @Test
    fun theEntryCountBoundIsLiteral() {
        val ranks = (0 until 100000).joinToString(",")
        val head = "beid-sigil-presence\t1\nwindows\t100000\n"
        val onePeer = "${head}peers\t1\npeer\t${token(1)}\t$ranks\nend\n"
        assertTrue(decodeSigilPresenceSnapshot(onePeer).isSuccess, "100,000 entries")
        val onePlus = "${head}peers\t2\npeer\t${token(1)}\t$ranks\npeer\t${token(2)}\t0\nend\n"
        assertDecodeRejected(onePlus, "invalid_snapshot")
    }

    @Test
    fun theByteCapIsLiteral() {
        val limit = 8 * 1024 * 1024
        assertDecodeRejected("x".repeat(limit + 1), "snapshot_too_large")
        // Exactly at the cap is not "too large"; it is merely not a snapshot.
        assertDecodeRejected("x".repeat(limit), "invalid_snapshot")
    }
}

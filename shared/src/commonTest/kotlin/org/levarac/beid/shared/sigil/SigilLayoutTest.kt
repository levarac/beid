package org.levarac.beid.shared.sigil

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Vectors for the shared Sigil layout family (beid#633).
 *
 * Every expected number below is a LITERAL. None is recomputed through a
 * production constant, because a vector that cites a constant by reference
 * moves both sides of its own comparison when that constant regresses and
 * never goes red (AGENTS.md, `scripts/mutation_check.py`). The golden
 * primitive lists and the hash vectors were produced by an independent
 * reference implementation written outside this module, not by running the
 * code under test.
 *
 * The literal hash and angle vectors are the contract for the angle
 * derivation. An implementation that does not call this module is expected to
 * reproduce them, not to re-derive the hash.
 *
 * Outside this evidence: the drawing itself (native), and that the iOS-target
 * compilation of these tests runs (it is compiled here, not executed).
 */
class SigilLayoutTest {

    private data class P(
        val kind: SigilPrimitiveKind,
        val x: Double,
        val y: Double,
        val x2: Double,
        val y2: Double,
        val radius: Double,
        val lineWidth: Double,
    )

    private fun SigilLayout.all(): List<SigilPrimitive> =
        (0 until primitiveCount).map { assertNotNull(primitiveAt(it)) }

    private fun SigilLayout.angles(): List<Triple<String, Int, Double>> =
        (0 until peerCount).map { index ->
            val peer = assertNotNull(peerAt(index))
            Triple(peer.peerKey, peer.baseAngleDegrees, peer.angleDegrees)
        }

    private fun near(expected: Double, actual: Double, label: String) {
        assertTrue(abs(expected - actual) <= 1e-9, "$label: expected $expected, got $actual")
    }

    private fun assertPrimitives(expected: List<P>, layout: SigilLayout) {
        assertTrue(layout.isSuccess, "layout failed: ${layout.errorCode}")
        val actual = layout.all()
        assertEquals(expected.map { it.kind }, actual.map { it.kind }, "primitive kinds/order")
        expected.zip(actual).forEachIndexed { index, (e, a) ->
            near(e.x, a.x, "[$index] x")
            near(e.y, a.y, "[$index] y")
            near(e.x2, a.x2, "[$index] x2")
            near(e.y2, a.y2, "[$index] y2")
            near(e.radius, a.radius, "[$index] radius")
            near(e.lineWidth, a.lineWidth, "[$index] lineWidth")
        }
    }

    private fun input(windowCount: Int, vararg entries: Triple<String, Int, Int>): SigilInput {
        val input = createSigilInput(windowCount)
        entries.forEach { (key, window, presence) ->
            assertTrue(addSigilPresence(input, key, window, presence), "rejected $key/$window/$presence")
        }
        return input
    }

    private fun sameLayout(a: SigilLayout, b: SigilLayout) {
        assertEquals(a.isSuccess, b.isSuccess)
        assertEquals(a.errorCode, b.errorCode)
        assertEquals(a.isMini, b.isMini)
        assertEquals(a.ringCount, b.ringCount)
        assertEquals(a.windowsPerRing, b.windowsPerRing)
        assertEquals(a.windowCount, b.windowCount)
        assertEquals(a.mutualPeerCount, b.mutualPeerCount)
        assertEquals(a.detectedPeerCount, b.detectedPeerCount)
        assertEquals(a.angles(), b.angles())
        val left = a.all()
        val right = b.all()
        assertEquals(left.size, right.size)
        left.zip(right).forEach { (l, r) ->
            assertEquals(
                listOf(l.kind, l.x, l.y, l.x2, l.y2, l.radius, l.lineWidth),
                listOf(r.kind, r.x, r.y, r.x2, r.y2, r.radius, r.lineWidth),
            )
        }
    }

    private val goldenEntries = arrayOf(
        Triple("peer-a", 0, 2), Triple("peer-a", 1, 2), Triple("peer-a", 2, 1),
        Triple("peer-b", 1, 1), Triple("peer-b", 2, 1), Triple("peer-b", 3, 2),
        Triple("peer-c", 0, 1), Triple("peer-c", 3, 2),
    )

    // --- AC1: golden vectors -------------------------------------------------

    /** Catches any drift in radii, widths, angles, variant choice or draw order. */
    @Test
    fun goldenThreePeersFourWindowsDisc200() {
        val layout = layoutSigil(input(4, *goldenEntries), 200.0, SigilGround.DISC)
        assertFalse(layout.isMini)
        assertEquals(4, layout.ringCount)
        assertEquals(1, layout.windowsPerRing)
        assertEquals(
            listOf(Triple("peer-a", 71, 71.0), Triple("peer-b", 162, 162.0), Triple("peer-c", 253, 253.0)),
            layout.angles(),
        )
        assertPrimitives(
            listOf(
                P(SigilPrimitiveKind.GROUND_DISC, 100.0, 100.0, 100.0, 100.0, 100.0, 0.0),
                P(SigilPrimitiveKind.RING, 100.0, 100.0, 100.0, 100.0, 30.0, 1.0),
                P(SigilPrimitiveKind.RING, 100.0, 100.0, 100.0, 100.0, 47.33333333333333, 1.0),
                P(SigilPrimitiveKind.RING, 100.0, 100.0, 100.0, 100.0, 64.66666666666666, 1.0),
                P(SigilPrimitiveKind.RING, 100.0, 100.0, 100.0, 100.0, 82.0, 1.0),
                P(SigilPrimitiveKind.DETECTED_LINE, 115.41022597763875, 144.75454591170097, 121.0534073215628, 161.1435345554225, 0.0, 1.2),
                P(SigilPrimitiveKind.DETECTED_LINE, 54.983324895362735, 114.62680440041419, 38.49834527958008, 119.98309896957994, 0.0, 1.2),
                P(SigilPrimitiveKind.DETECTED_LINE, 38.49834527958008, 119.98309896957994, 22.013365663797416, 125.3393935387457, 0.0, 1.2),
                P(SigilPrimitiveKind.MUTUAL_LINE, 109.7670446337147, 128.3655572679795, 115.41022597763875, 144.75454591170097, 0.0, 2.4),
                P(SigilPrimitiveKind.DETECTED_DOT, 121.0534073215628, 161.1435345554225, 121.0534073215628, 161.1435345554225, 1.8, 0.0),
                P(SigilPrimitiveKind.DETECTED_DOT, 54.983324895362735, 114.62680440041419, 54.983324895362735, 114.62680440041419, 1.8, 0.0),
                P(SigilPrimitiveKind.DETECTED_DOT, 38.49834527958008, 119.98309896957994, 38.49834527958008, 119.98309896957994, 1.8, 0.0),
                P(SigilPrimitiveKind.DETECTED_DOT, 91.22884885831789, 71.31085732110894, 91.22884885831789, 71.31085732110894, 1.8, 0.0),
                P(SigilPrimitiveKind.MUTUAL_DOT, 109.7670446337147, 128.3655572679795, 109.7670446337147, 128.3655572679795, 3.0, 0.0),
                P(SigilPrimitiveKind.MUTUAL_DOT, 115.41022597763875, 144.75454591170097, 115.41022597763875, 144.75454591170097, 3.0, 0.0),
                P(SigilPrimitiveKind.MUTUAL_DOT, 22.013365663797416, 125.3393935387457, 22.013365663797416, 125.3393935387457, 3.0, 0.0),
                P(SigilPrimitiveKind.MUTUAL_DOT, 76.02552021273556, 21.583010011031107, 76.02552021273556, 21.583010011031107, 3.0, 0.0),
                P(SigilPrimitiveKind.CENTER_DOT, 100.0, 100.0, 100.0, 100.0, 11.0, 0.0),
            ),
            layout,
        )
    }

    /** Catches mini drift: no rings, no detected marks, strands + isolated points only. */
    @Test
    fun goldenMiniSize60None() {
        val layout = layoutSigil(
            input(
                4,
                Triple("peer-a", 0, 2), Triple("peer-a", 1, 2), Triple("peer-a", 2, 1),
                Triple("peer-b", 1, 1), Triple("peer-b", 2, 1), Triple("peer-b", 3, 2),
                Triple("peer-c", 0, 2), Triple("peer-c", 1, 1), Triple("peer-c", 2, 2), Triple("peer-c", 3, 2),
            ),
            60.0,
            SigilGround.NONE,
        )
        assertTrue(layout.isMini)
        assertPrimitives(
            listOf(
                P(SigilPrimitiveKind.MUTUAL_LINE, 32.930113390114414, 38.50966718039385, 34.948635947748784, 44.37188234910961, 0.0, 2.0),
                P(SigilPrimitiveKind.MUTUAL_LINE, 23.743245518933428, 9.535078222391046, 21.930540949652453, 3.6059887354202225, 0.0, 2.0),
                P(SigilPrimitiveKind.MUTUAL_DOT, 3.7508401502537616, 38.528869044748554, 3.7508401502537616, 38.528869044748554, 1.0, 0.0),
                P(SigilPrimitiveKind.MUTUAL_DOT, 27.368654657495366, 21.393257196332684, 27.368654657495366, 21.393257196332684, 1.0, 0.0),
                P(SigilPrimitiveKind.CENTER_DOT, 30.0, 30.0, 30.0, 30.0, 4.8, 0.0),
            ),
            layout,
        )
    }

    /** Catches outline-ground drift and a divide-by-(W-1) regression at W = 1. */
    @Test
    fun goldenSingleWindowOutline200() {
        val layout = layoutSigil(input(1, Triple("peer-a", 0, 2)), 200.0, SigilGround.OUTLINE)
        assertEquals(1, layout.ringCount)
        assertPrimitives(
            listOf(
                P(SigilPrimitiveKind.GROUND_OUTLINE, 100.0, 100.0, 100.0, 100.0, 99.4, 1.2),
                P(SigilPrimitiveKind.RING, 100.0, 100.0, 100.0, 100.0, 30.0, 1.0),
                P(SigilPrimitiveKind.MUTUAL_DOT, 109.7670446337147, 128.3655572679795, 109.7670446337147, 128.3655572679795, 3.0, 0.0),
                P(SigilPrimitiveKind.CENTER_DOT, 100.0, 100.0, 100.0, 100.0, 11.0, 0.0),
            ),
            layout,
        )
    }

    /** Catches the no-disc r_max (0.46) being replaced by the disc one (0.41) or vice versa. */
    @Test
    fun outermostRingRadiusDependsOnGround() {
        val entries = arrayOf(Triple("peer-a", 0, 1), Triple("peer-a", 1, 1))
        fun outer(ground: SigilGround): Double =
            layoutSigil(input(2, *entries), 200.0, ground).all().last { it.kind == SigilPrimitiveKind.RING }.radius
        near(82.0, outer(SigilGround.DISC), "disc r_max")
        near(92.0, outer(SigilGround.OUTLINE), "outline r_max")
        near(92.0, outer(SigilGround.NONE), "none r_max")
        val none = layoutSigil(input(2, *entries), 200.0, SigilGround.NONE).all()
        assertEquals(
            listOf(SigilPrimitiveKind.RING, SigilPrimitiveKind.RING, SigilPrimitiveKind.DETECTED_LINE,
                SigilPrimitiveKind.DETECTED_DOT, SigilPrimitiveKind.DETECTED_DOT, SigilPrimitiveKind.CENTER_DOT),
            none.map { it.kind },
        )
        near(30.0, none[0].radius, "none r0")
    }

    // --- Hash (invariant 1) --------------------------------------------------

    /** Catches any change to FNV-1a 64 (offset, prime, byte order, UTF-8) or its reduction. */
    @Test
    fun pinnedHashVectors() {
        assertEquals(0xb1df888881737297uL, sigilPeerHash("peer-a"))
        assertEquals(0xaf63dc4c8601ec8cuL, sigilPeerHash("a"))
        assertEquals(0xee9ee2b5c854ef87uL, sigilPeerHash("日本語"))
        assertEquals(0x78da2a19575d8518uL, sigilPeerHash("p12"))
        assertEquals(71, sigilBaseAngleDegrees("peer-a"))
        assertEquals(162, sigilBaseAngleDegrees("peer-b"))
        assertEquals(253, sigilBaseAngleDegrees("peer-c"))
        assertEquals(196, sigilBaseAngleDegrees("a"))
        assertEquals(111, sigilBaseAngleDegrees("日本語"))
        assertEquals(60, sigilBaseAngleDegrees("peer-0"))
        assertEquals(0, sigilBaseAngleDegrees("k103"))
        assertEquals(359, sigilBaseAngleDegrees("k216"))
    }

    // --- Determinism and order independence (invariants 1, 2) ---------------

    /** Catches process-seeded hashing or iteration-order leaks into the output. */
    @Test
    fun sameInputYieldsIdenticalLayout() {
        val first = layoutSigil(input(4, *goldenEntries), 200.0, SigilGround.DISC)
        val second = layoutSigil(input(4, *goldenEntries), 200.0, SigilGround.DISC)
        sameLayout(first, second)
    }

    /** Catches insertion order leaking into angles or draw order. */
    @Test
    fun shuffledInsertionOrderYieldsIdenticalLayout() {
        val entries = (0 until 40).flatMap { peer ->
            (0 until 13).mapNotNull { window ->
                val presence = (peer * 7 + window * 3) % 3
                if (presence == 0) null else Triple("n$peer", window, presence)
            }
        }
        val forward = layoutSigil(input(13, *entries.toTypedArray()), 200.0, SigilGround.NONE)
        val reversed = layoutSigil(input(13, *entries.reversed().toTypedArray()), 200.0, SigilGround.NONE)
        val shuffled = layoutSigil(input(13, *entries.shuffled(kotlin.random.Random(633)).toTypedArray()), 200.0, SigilGround.NONE)
        sameLayout(forward, reversed)
        sameLayout(forward, shuffled)
        assertTrue(forward.primitiveCount > 0)
    }

    /** Catches last-write-wins (or first-write-wins) on duplicate (peer, window) entries. */
    @Test
    fun duplicateEntriesResolveByMax() {
        val up = input(1, Triple("peer-a", 0, 1), Triple("peer-a", 0, 2))
        val down = input(1, Triple("peer-a", 0, 2), Triple("peer-a", 0, 1))
        val upLayout = layoutSigil(up, 200.0, SigilGround.NONE)
        sameLayout(upLayout, layoutSigil(down, 200.0, SigilGround.NONE))
        assertEquals(1, upLayout.all().count { it.kind == SigilPrimitiveKind.MUTUAL_DOT })
        assertEquals(0, upLayout.all().count { it.kind == SigilPrimitiveKind.DETECTED_DOT })
    }

    /** Catches a re-registration resetting a peer's presences, which would make order matter. */
    @Test
    fun duplicatePeerRegistrationIsANoOpThatSucceeds() {
        val a = createSigilInput(2)
        assertTrue(addSigilPresence(a, "peer-a", 0, 2))
        assertTrue(addSigilPeer(a, "peer-a"))
        assertTrue(addSigilPeer(a, "peer-a"))
        val b = createSigilInput(2)
        assertTrue(addSigilPeer(b, "peer-a"))
        assertTrue(addSigilPresence(b, "peer-a", 0, 2))
        val layout = layoutSigil(a, 200.0, SigilGround.NONE)
        sameLayout(layout, layoutSigil(b, 200.0, SigilGround.NONE))
        assertEquals(1, layout.all().count { it.kind == SigilPrimitiveKind.MUTUAL_DOT })
    }

    /** Catches a layout that drains or aliases its input. */
    @Test
    fun layoutIsAReadAndAResultIsASnapshot() {
        val source = input(4, *goldenEntries)
        val before = layoutSigil(source, 200.0, SigilGround.DISC)
        val count = before.primitiveCount
        sameLayout(before, layoutSigil(source, 200.0, SigilGround.DISC))
        assertTrue(addSigilPresence(source, "peer-z", 0, 1))
        assertEquals(count, before.primitiveCount)
        assertEquals(3, before.peerCount)
        assertEquals(4, layoutSigil(source, 200.0, SigilGround.DISC).peerCount)
    }

    // --- Ring aggregation ----------------------------------------------------

    private fun rings(windowCount: Int): Pair<Int, Int> {
        val layout = layoutSigil(input(windowCount, Triple("peer-a", windowCount - 1, 1)), 200.0, SigilGround.NONE)
        assertTrue(layout.isSuccess)
        assertEquals(layout.ringCount, layout.all().count { it.kind == SigilPrimitiveKind.RING })
        return layout.ringCount to layout.windowsPerRing
    }

    /** Catches a wrong bin size, bin anchor, or ring count at every boundary. */
    @Test
    fun ringCountsAtWindowBoundaries() {
        assertEquals(1 to 1, rings(1))
        assertEquals(5 to 1, rings(5))
        assertEquals(6 to 1, rings(6))
        assertEquals(12 to 1, rings(12))
        assertEquals(7 to 2, rings(13))
        assertEquals(12 to 2, rings(24))
        assertEquals(9 to 3, rings(25))
        assertEquals(12 to 3, rings(36))
        assertEquals(10 to 4, rings(37))
        assertEquals(12 to 8334, rings(100_000))
    }

    /** Catches a merged ring taking min/last instead of max, or anchoring bins at the newest window. */
    @Test
    fun mergedRingTakesMaxAnchoredAtOldestWindow() {
        // W = 13, b = 2: windows {0,1} -> ring 0, ..., {12} -> ring 6.
        val layout = layoutSigil(
            input(13, Triple("peer-a", 0, 1), Triple("peer-a", 1, 2), Triple("peer-a", 12, 1)),
            200.0,
            SigilGround.NONE,
        )
        assertEquals(7, layout.ringCount)
        val dots = layout.all().filter { it.kind == SigilPrimitiveKind.MUTUAL_DOT || it.kind == SigilPrimitiveKind.DETECTED_DOT }
        assertEquals(listOf(SigilPrimitiveKind.DETECTED_DOT, SigilPrimitiveKind.MUTUAL_DOT), dots.map { it.kind })
        // mutual dot on ring 0 (r = 30): peer-a at 71 degrees.
        near(109.7670446337147, dots[1].x, "ring-0 mutual x")
        near(128.3655572679795, dots[1].y, "ring-0 mutual y")
        // detected dot on ring 6 (r = 92).
        near(129.95227021005843, dots[0].x, "ring-6 detected x")
        near(186.98770895513712, dots[0].y, "ring-6 detected y")
        // rings 0 and 6 are not consecutive: no line.
        assertEquals(0, layout.all().count { it.kind == SigilPrimitiveKind.DETECTED_LINE || it.kind == SigilPrimitiveKind.MUTUAL_LINE })
    }

    /** Catches a merged ring fabricating presence 2 out of presence 1 (invariant 7). */
    @Test
    fun presenceTwoAppearsOnlyWhereSupplied() {
        val entries = (0 until 30).flatMap { peer -> (0 until 25).map { Triple("n$peer", it, 1) } }
        for (size in listOf(60.0, 200.0)) {
            val layout = layoutSigil(input(25, *entries.toTypedArray()), size, SigilGround.NONE)
            assertEquals(
                0,
                layout.all().count { it.kind == SigilPrimitiveKind.MUTUAL_DOT || it.kind == SigilPrimitiveKind.MUTUAL_LINE },
                "size $size",
            )
        }
        val mini = layoutSigil(input(25, *entries.toTypedArray()), 60.0, SigilGround.NONE)
        assertEquals(listOf(SigilPrimitiveKind.CENTER_DOT), mini.all().map { it.kind })
    }

    // --- Separation (invariants 3, 4) ---------------------------------------

    /** Catches an adjustment applied when nothing collides. */
    @Test
    fun anglesAreUntouchedWhenNothingCollides() {
        val layout = layoutSigil(input(4, *goldenEntries), 200.0, SigilGround.DISC)
        layout.angles().forEach { (_, base, angle) -> assertEquals(base.toDouble(), angle) }
    }

    /**
     * Catches the one-turn offset being dropped for the first wrapped peer: the
     * sweep starts at 200 (after the widest gap), so 10 and 20 are reached only
     * after wrapping and must still keep their bases.
     */
    @Test
    fun wrappedPeersOutsideAClusterKeepTheirBaseAngles() {
        val layout = layoutSigil(
            input(1, Triple("k71", 0, 1), Triple("k279", 0, 1), Triple("k778", 0, 1)),
            200.0,
            SigilGround.NONE,
        )
        assertEquals(
            listOf(Triple("k71", 10, 10.0), Triple("k279", 20, 20.0), Triple("k778", 200, 200.0)),
            layout.angles(),
        )
    }

    /**
     * Catches the sweep starting after the LAST of several equally wide gaps
     * instead of the first. At 86 peers that choice moves these peers (and uses
     * the backward pass: n66's base is 9, and it ends at 8).
     */
    @Test
    fun widestGapTieStartsAfterTheFirstOne() {
        val angles = peers(86).angles().associate { it.first to it.third }
        assertEquals(8.0, angles.getValue("n66"))
        assertEquals(12.0, angles.getValue("n62"))
        assertEquals(16.0, angles.getValue("n81"))
        assertEquals(20.0, angles.getValue("n85"))
        assertEquals(9, sigilBaseAngleDegrees("n66"))
    }

    @Test
    fun singlePeerKeepsItsBaseAngle() {
        val layout = layoutSigil(input(1, Triple("k216", 0, 1)), 200.0, SigilGround.NONE)
        assertEquals(listOf(Triple("k216", 359, 359.0)), layout.angles())
    }

    /** Catches a non-deterministic or insertion-order tie-break for an exact hash-angle collision. */
    @Test
    fun exactAngleCollisionSeparatesDeterministically() {
        val one = layoutSigil(input(1, Triple("p12", 0, 1), Triple("p78", 0, 1)), 200.0, SigilGround.NONE)
        val two = layoutSigil(input(1, Triple("p78", 0, 1), Triple("p12", 0, 1)), 200.0, SigilGround.NONE)
        assertEquals(listOf(Triple("p78", 352, 352.0), Triple("p12", 352, 356.0)), one.angles())
        assertEquals(one.angles(), two.angles())
    }

    /** Catches separation that ignores the 0/360 wrap or starts at the wrong gap. */
    @Test
    fun clusterAcrossZeroSeparatesAroundTheCircle() {
        val layout = layoutSigil(
            input(
                1,
                Triple("k291", 0, 1), Triple("k216", 0, 1), Triple("k103", 0, 1),
                Triple("k411", 0, 1), Triple("k180", 0, 1), Triple("k297", 0, 1),
            ),
            200.0,
            SigilGround.NONE,
        )
        assertEquals(
            listOf(
                Triple("k216", 359, 2.0),
                Triple("k103", 0, 6.0),
                Triple("k411", 0, 10.0),
                Triple("k180", 1, 14.0),
                Triple("k297", 180, 180.0),
                Triple("k291", 358, 358.0),
            ),
            layout.angles(),
        )
    }

    private fun assertSeparated(layout: SigilLayout, expectedGap: Double) {
        val peers = layout.angles()
        val n = peers.size
        val sorted = peers.sortedBy { it.third }
        sorted.forEach { assertTrue(it.third >= 0.0 && it.third < 360.0, "angle out of range: $it") }
        for (i in 0 until n) {
            val a = sorted[i].third
            val b = if (i + 1 < n) sorted[i + 1].third else sorted[0].third + 360.0
            assertTrue(b - a >= expectedGap - 1e-9, "gap ${b - a} < $expectedGap between ${sorted[i]} and ${sorted[(i + 1) % n]}")
        }
        // circular order by (base angle, hash) is preserved: rotating the adjusted order
        // to its minimum base must give a base sequence that is non-decreasing.
        val bases = sorted.map { it.second }
        val start = (0 until n).first { i ->
            (0 until n - 1).all { j -> bases[(i + j) % n] <= bases[(i + j + 1) % n] }
        }
        val rotated = (0 until n).map { sorted[(start + it) % n] }
        for (j in 0 until n - 1) {
            val (ka, ba, _) = rotated[j]
            val (kb, bb, _) = rotated[j + 1]
            assertTrue(ba < bb || (ba == bb && sigilPeerHash(ka) < sigilPeerHash(kb)), "order broken at $ka/$kb")
        }
    }

    private fun peers(n: Int): SigilLayout =
        layoutSigil(input(1, *(0 until n).map { Triple("n$it", 0, 1) }.toTypedArray()), 200.0, SigilGround.NONE)

    @Test
    fun ninetyPeersAreFourDegreesApart() {
        val layout = peers(90)
        assertEquals(90, layout.peerCount)
        assertSeparated(layout, 4.0)
    }

    @Test
    fun ninetyOnePeersShrinkTheGapToFitTheCircle() {
        val layout = peers(91)
        assertSeparated(layout, 3.956043956043956)
    }

    @Test
    fun threeHundredPeersAreSeparated() {
        val layout = peers(300)
        assertEquals(300, layout.peerCount)
        assertSeparated(layout, 1.2)
    }

    @Test
    fun twentyPeersUseTheFourDegreeGap() {
        assertSeparated(peers(20), 4.0)
    }

    /** Catches an all-zero peer taking an angular slot or shifting another peer. */
    @Test
    fun allZeroPeerTakesNoSlot() {
        val with = createSigilInput(1)
        assertTrue(addSigilPeer(with, "k411"))
        assertTrue(addSigilPresence(with, "k103", 0, 1))
        val without = input(1, Triple("k103", 0, 1))
        val layout = layoutSigil(with, 200.0, SigilGround.NONE)
        assertEquals(listOf(Triple("k103", 0, 0.0)), layout.angles())
        sameLayout(layout, layoutSigil(without, 200.0, SigilGround.NONE))
    }

    @Test
    fun onlyAllZeroPeersDrawNoPeerMarks() {
        val zero = createSigilInput(3)
        assertTrue(addSigilPeer(zero, "peer-a"))
        val layout = layoutSigil(zero, 200.0, SigilGround.NONE)
        assertEquals(0, layout.peerCount)
        assertEquals(
            listOf(SigilPrimitiveKind.RING, SigilPrimitiveKind.RING, SigilPrimitiveKind.RING, SigilPrimitiveKind.CENTER_DOT),
            layout.all().map { it.kind },
        )
    }

    @Test
    fun emptyPeerSetDrawsOnlyTheCenterAmongMarks() {
        val full = layoutSigil(createSigilInput(4), 200.0, SigilGround.DISC)
        assertTrue(full.isSuccess)
        assertEquals(
            listOf(SigilPrimitiveKind.GROUND_DISC, SigilPrimitiveKind.RING, SigilPrimitiveKind.RING,
                SigilPrimitiveKind.RING, SigilPrimitiveKind.RING, SigilPrimitiveKind.CENTER_DOT),
            full.all().map { it.kind },
        )
        val mini = layoutSigil(createSigilInput(4), 60.0, SigilGround.NONE)
        assertTrue(mini.isSuccess)
        assertEquals(listOf(SigilPrimitiveKind.CENTER_DOT), mini.all().map { it.kind })
    }

    /** Catches the mini re-separating over its own (smaller) drawn set. */
    @Test
    fun peerAngleIsIdenticalInFullAndMini() {
        // p12 / p78 collide at 352. p78 is detected-only, so the mini draws only p12,
        // but p12 must keep the angle it got in the full variant (356), not 352.
        val source = input(1, Triple("p12", 0, 2), Triple("p78", 0, 1))
        val full = layoutSigil(source, 200.0, SigilGround.NONE)
        val mini = layoutSigil(source, 60.0, SigilGround.NONE)
        assertEquals(full.angles(), mini.angles())
        assertEquals(356.0, mini.angles().single { it.first == "p12" }.third)
        val dot = mini.all().single { it.kind == SigilPrimitiveKind.MUTUAL_DOT }
        // r0 = 9 at size 60, angle 356.
        near(38.978076452338414, dot.x, "mini x")
        near(29.37219173630287, dot.y, "mini y")
    }

    // --- Variant, size bounds (invariant 5) ---------------------------------

    @Test
    fun variantThresholdIsSixtyInclusive() {
        assertTrue(layoutSigil(createSigilInput(1), 60.0, SigilGround.NONE).isMini)
        assertFalse(layoutSigil(createSigilInput(1), 60.000001, SigilGround.NONE).isMini)
        assertTrue(layoutSigil(createSigilInput(1), 25.0, SigilGround.NONE).isMini)
    }

    @Test
    fun invalidSizesAreRejectedExplicitly() {
        for (size in listOf(24.999999, 0.0, -1.0, -0.0, Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            val layout = layoutSigil(input(1, Triple("peer-a", 0, 2)), size, SigilGround.NONE)
            assertFalse(layout.isSuccess, "size $size")
            assertEquals("invalid_size", layout.errorCode, "size $size")
            assertEquals(0, layout.primitiveCount)
            assertEquals(0, layout.peerCount)
            assertFalse(layout.isMini)
            assertEquals(0, layout.ringCount)
            assertEquals(0, layout.windowsPerRing)
        }
        val ok = layoutSigil(input(1, Triple("peer-a", 0, 2)), 25.0, SigilGround.NONE)
        assertTrue(ok.isSuccess)
        assertNull(ok.errorCode)
    }

    private fun assertInBounds(layout: SigilLayout) {
        val size = layout.size
        val eps = 1e-9
        layout.all().forEachIndexed { index, p ->
            val extent = when (p.kind) {
                SigilPrimitiveKind.DETECTED_LINE, SigilPrimitiveKind.MUTUAL_LINE -> p.lineWidth / 2
                else -> p.radius + p.lineWidth / 2
            }
            for (v in listOf(p.x, p.y, p.x2, p.y2)) {
                assertTrue(v - extent >= -eps && v + extent <= size + eps, "size $size [$index] ${p.kind} out of bounds")
            }
        }
    }

    /** Dense input with peers on all four axes, every ring present. */
    private fun denseInput(windowCount: Int): SigilInput {
        val source = createSigilInput(windowCount)
        val keys = listOf("k103", "k215", "k297", "k181") + (0 until 60).map { "n$it" }
        keys.forEachIndexed { index, key ->
            for (window in 0 until windowCount) {
                assertTrue(addSigilPresence(source, key, window, if ((index + window) % 5 == 0) 1 else 2))
            }
        }
        return source
    }

    @Test
    fun everyPrimitiveStaysInsideTheBounds() {
        for (size in listOf(25.0, 30.0, 45.5, 60.0, 60.000001, 76.0, 190.0, 200.0, 240.0, 290.0, 1000.0)) {
            for (ground in SigilGround.entries) {
                for (windowCount in listOf(1, 12, 25)) {
                    val layout = layoutSigil(denseInput(windowCount), size, ground)
                    assertTrue(layout.isSuccess)
                    assertTrue(layout.primitiveCount > 1)
                    assertInBounds(layout)
                }
            }
        }
    }

    /** The minimum size is where the outermost mini mark just touches the edge. */
    @Test
    fun minimumSizeTouchesTheEdgeExactly() {
        val layout = layoutSigil(input(1, Triple("k103", 0, 2)), 25.0, SigilGround.NONE)
        val dot = layout.all().single { it.kind == SigilPrimitiveKind.MUTUAL_DOT }
        // W = 1 puts the dot on r0; use two windows so the dot sits on r_max.
        near(1.0, dot.radius, "mini point radius")
        val outer = layoutSigil(input(2, Triple("k103", 1, 2)), 25.0, SigilGround.NONE)
        val edge = outer.all().single { it.kind == SigilPrimitiveKind.MUTUAL_DOT }
        near(24.0, edge.x, "edge x")
        near(12.5, edge.y, "edge y")
        near(25.0, edge.x + edge.radius, "edge extent")
    }

    /** AC3: a dense 60pt mini stays legible and inside its bounds. */
    @Test
    fun miniAtSixtyWithDenseMutualStrands() {
        val layout = layoutSigil(denseInput(12), 60.0, SigilGround.NONE)
        assertTrue(layout.isMini)
        val all = layout.all()
        assertTrue(all.count { it.kind == SigilPrimitiveKind.MUTUAL_LINE } > 100)
        assertTrue(all.any { it.kind == SigilPrimitiveKind.MUTUAL_DOT })
        all.filter { it.kind == SigilPrimitiveKind.MUTUAL_LINE }.forEach { assertEquals(2.0, it.lineWidth) }
        all.filter { it.kind == SigilPrimitiveKind.MUTUAL_DOT }.forEach { assertEquals(1.0, it.radius) }
        assertEquals(setOf(SigilPrimitiveKind.MUTUAL_LINE, SigilPrimitiveKind.MUTUAL_DOT, SigilPrimitiveKind.CENTER_DOT), all.map { it.kind }.toSet())
        near(4.8, all.last().radius, "mini center")
        assertInBounds(layout)
    }

    /** Catches a width or radius that stops scaling with k = size / 200. */
    @Test
    fun fullVariantWidthsScaleWithSize() {
        val full = layoutSigil(input(2, Triple("peer-a", 0, 2), Triple("peer-a", 1, 2)), 290.0, SigilGround.DISC)
        val line = full.all().single { it.kind == SigilPrimitiveKind.MUTUAL_LINE }
        near(3.48, line.lineWidth, "full mutual width at 290")
        near(4.35, full.all().first { it.kind == SigilPrimitiveKind.MUTUAL_DOT }.radius, "full mutual dot at 290")
        near(15.95, full.all().last().radius, "full center at 290")
        near(1.45, full.all().first { it.kind == SigilPrimitiveKind.RING }.lineWidth, "ring width at 290")
        near(145.0, full.all().first().radius, "disc radius at 290")
    }

    // --- Draw order (P2) -----------------------------------------------------

    @Test
    fun drawOrderIsByLayer() {
        val layout = layoutSigil(denseInput(6), 200.0, SigilGround.OUTLINE)
        val kinds = layout.all().map { it.kind }
        val layerOrder = listOf(
            SigilPrimitiveKind.GROUND_OUTLINE, SigilPrimitiveKind.RING, SigilPrimitiveKind.DETECTED_LINE,
            SigilPrimitiveKind.MUTUAL_LINE, SigilPrimitiveKind.DETECTED_DOT, SigilPrimitiveKind.MUTUAL_DOT,
            SigilPrimitiveKind.CENTER_DOT,
        )
        assertEquals(layerOrder, kinds.distinct())
        assertEquals(kinds, kinds.sortedBy { layerOrder.indexOf(it) })
    }

    // --- Boundary checks (invariant 6) --------------------------------------

    @Test
    fun invalidPresenceIsRejected() {
        val source = createSigilInput(2)
        assertFalse(addSigilPresence(source, "peer-a", 0, 0))
        assertFalse(addSigilPresence(source, "peer-a", 0, 3))
        assertFalse(addSigilPresence(source, "peer-a", 0, -1))
        assertTrue(addSigilPresence(source, "peer-a", 0, 1))
        assertTrue(addSigilPresence(source, "peer-a", 1, 2))
    }

    @Test
    fun windowIndexOutOfRangeIsRejected() {
        val source = createSigilInput(3)
        assertFalse(addSigilPresence(source, "peer-a", -1, 1))
        assertFalse(addSigilPresence(source, "peer-a", 3, 1))
        assertTrue(addSigilPresence(source, "peer-a", 2, 1))
        assertTrue(addSigilPresence(source, "peer-a", 0, 1))
        // A rejected entry does not register the peer either.
        val empty = createSigilInput(3)
        assertFalse(addSigilPresence(empty, "peer-a", 3, 1))
        assertEquals(0, layoutSigil(empty, 200.0, SigilGround.NONE).peerCount)
    }

    @Test
    fun invalidWindowCountFailsWhole() {
        for (windowCount in listOf(0, -1, 100_001)) {
            val source = createSigilInput(windowCount)
            assertFalse(addSigilPresence(source, "peer-a", 0, 1), "W $windowCount")
            assertFalse(addSigilPeer(source, "peer-a"), "W $windowCount")
            val layout = layoutSigil(source, 200.0, SigilGround.NONE)
            assertFalse(layout.isSuccess)
            assertEquals("invalid_window_count", layout.errorCode)
            assertEquals(0, layout.primitiveCount)
            assertEquals(0, layout.peerCount)
            assertFalse(layout.isMini)
            assertEquals(0, layout.ringCount)
            assertEquals(0, layout.windowsPerRing)
        }
        assertTrue(layoutSigil(createSigilInput(100_000), 200.0, SigilGround.NONE).isSuccess)
        assertTrue(layoutSigil(createSigilInput(1), 200.0, SigilGround.NONE).isSuccess)
    }

    @Test
    fun peerKeyShapeIsChecked() {
        val source = createSigilInput(1)
        assertFalse(addSigilPresence(source, "", 0, 1))
        assertFalse(addSigilPeer(source, ""))
        assertTrue(addSigilPresence(source, "x".repeat(4096), 0, 1))
        assertFalse(addSigilPresence(source, "x".repeat(4097), 0, 1))
        // bytes, not characters: 1366 three-byte characters = 4098 bytes.
        assertFalse(addSigilPresence(source, "語".repeat(1366), 0, 1))
        assertTrue(addSigilPresence(source, "語".repeat(1365), 0, 1))
        assertFalse(addSigilPresence(source, "\uD800", 0, 1))
    }

    @Test
    fun peerCapacityIsBounded() {
        val source = createSigilInput(1)
        for (i in 0 until 1024) assertTrue(addSigilPresence(source, "n$i", 0, 1), "peer $i")
        assertFalse(addSigilPresence(source, "n1024", 0, 1))
        assertFalse(addSigilPeer(source, "n1024"))
        // an existing peer is still updatable and re-registrable at the cap.
        assertTrue(addSigilPresence(source, "n0", 0, 2))
        assertTrue(addSigilPeer(source, "n0"))
        assertEquals(1024, layoutSigil(source, 200.0, SigilGround.NONE).peerCount)
    }

    @Test
    fun entryCapacityIsBounded() {
        val source = createSigilInput(100)
        var accepted = 0
        outer@ for (peer in 0 until 1001) {
            for (window in 0 until 100) {
                if (!addSigilPresence(source, "n$peer", window, 1)) break@outer
                accepted += 1
            }
        }
        assertEquals(100_000, accepted)
        assertFalse(addSigilPresence(source, "n1000", 1, 1))
        // updating an existing entry does not consume capacity.
        assertTrue(addSigilPresence(source, "n0", 0, 2))
        assertTrue(layoutSigil(source, 200.0, SigilGround.NONE).isSuccess)
    }

    // --- Peer and window counts (invariant 8) --------------------------------

    /** Catches either count drifting from the drawn-peer set it is supposed to split. */
    @Test
    fun peerCountsPartitionTheDrawnPeers() {
        val mixed = input(4, Triple("m", 0, 2), Triple("d1", 0, 1), Triple("d2", 3, 1))
        val layout = layoutSigil(mixed, 200.0, SigilGround.DISC)
        assertEquals(3, layout.peerCount)
        assertEquals(1, layout.mutualPeerCount)
        assertEquals(2, layout.detectedPeerCount)

        val allDetected = (0 until 30).flatMap { peer -> (0 until 25).map { Triple("n$peer", it, 1) } }
        val cases = listOf(
            input(4, *goldenEntries),
            mixed,
            input(1, Triple("peer-a", 0, 2)),
            input(13, Triple("peer-a", 0, 1), Triple("peer-a", 1, 2), Triple("peer-a", 12, 1)),
            input(25, *allDetected.toTypedArray()),
            createSigilInput(6),
        )
        for (source in cases) {
            for (size in listOf(25.0, 60.0, 200.0)) {
                for (ground in listOf(SigilGround.DISC, SigilGround.OUTLINE, SigilGround.NONE)) {
                    val each = layoutSigil(source, size, ground)
                    assertEquals(
                        each.peerCount,
                        each.mutualPeerCount + each.detectedPeerCount,
                        "W ${source.windowCount} size $size $ground",
                    )
                }
            }
        }
        // The two ends of the range: the golden input is all-mutual, the 30-peer one all-detected.
        val golden = layoutSigil(input(4, *goldenEntries), 200.0, SigilGround.DISC)
        assertEquals(3, golden.mutualPeerCount)
        assertEquals(0, golden.detectedPeerCount)
        val detected = layoutSigil(input(25, *allDetected.toTypedArray()), 200.0, SigilGround.NONE)
        assertEquals(0, detected.mutualPeerCount)
        assertEquals(30, detected.detectedPeerCount)
    }

    /**
     * The shape that actually ships. Presence 2 does not occur on-device
     * (AggregationRuntime passes mutual unconditionally false, DECISIONS
     * 2026-09-23), so the production Sigil is "0 mutual, N detected" in both
     * variants. Catches a mutual count that is really a drawn-peer count.
     */
    @Test
    fun productionShapeIsDetectedOnlyInBothVariants() {
        val entries = (0 until 13).flatMap { peer -> (0 until 6).map { Triple("peer-$peer", it, 1) } }
        for (size in listOf(60.0, 200.0)) {
            val layout = layoutSigil(input(6, *entries.toTypedArray()), size, SigilGround.NONE)
            assertEquals(13, layout.peerCount, "size $size")
            assertEquals(0, layout.mutualPeerCount, "size $size")
            assertEquals(13, layout.detectedPeerCount, "size $size")
            assertEquals(6, layout.windowCount, "size $size")
        }
    }

    /**
     * The case a primitive-derived count gets wrong, which is why these counts
     * exist. The mini emits no detected mark at all, so counting marks reports
     * 0 detected there; the full variant emits one dot PER RING, so counting
     * marks reports 5 detected and 3 mutual for the same 3 and 2 peers.
     */
    @Test
    fun countsAreTakenFromPresencesNotFromMarks() {
        val entries = arrayOf(
            Triple("m1", 0, 2), Triple("m1", 1, 2),
            Triple("m2", 0, 2),
            Triple("d1", 0, 1), Triple("d1", 1, 1),
            Triple("d2", 1, 1),
            Triple("d3", 0, 1), Triple("d3", 1, 1),
        )
        val mini = layoutSigil(input(2, *entries), 40.0, SigilGround.NONE)
        assertTrue(mini.isMini)
        assertEquals(5, mini.peerCount)
        assertEquals(2, mini.mutualPeerCount)
        assertEquals(3, mini.detectedPeerCount)
        assertEquals(
            0,
            mini.all().count {
                it.kind == SigilPrimitiveKind.DETECTED_DOT || it.kind == SigilPrimitiveKind.DETECTED_LINE
            },
            "the mini draws no detected mark, so there is nothing to count",
        )

        val full = layoutSigil(input(2, *entries), 200.0, SigilGround.NONE)
        assertFalse(full.isMini)
        assertEquals(2, full.mutualPeerCount)
        assertEquals(3, full.detectedPeerCount)
        assertEquals(5, full.all().count { it.kind == SigilPrimitiveKind.DETECTED_DOT })
        assertEquals(3, full.all().count { it.kind == SigilPrimitiveKind.MUTUAL_DOT })
    }

    /** Catches mutual being decided per ring, or by the newest ring, instead of by the max. */
    @Test
    fun peakPresenceOverTheRingsDecidesMutual() {
        val mutualFirst = layoutSigil(input(2, Triple("peer-a", 0, 2), Triple("peer-a", 1, 1)), 200.0, SigilGround.NONE)
        assertEquals(1, mutualFirst.peerCount)
        assertEquals(1, mutualFirst.mutualPeerCount)
        assertEquals(0, mutualFirst.detectedPeerCount)

        val mutualLast = layoutSigil(input(2, Triple("peer-a", 0, 1), Triple("peer-a", 1, 2)), 200.0, SigilGround.NONE)
        assertEquals(1, mutualLast.mutualPeerCount)
        assertEquals(0, mutualLast.detectedPeerCount)

        // W = 13, b = 2: both windows merge into ring 0, whose presence is the max.
        val merged = layoutSigil(input(13, Triple("peer-a", 0, 1), Triple("peer-a", 1, 2)), 200.0, SigilGround.NONE)
        assertEquals(7, merged.ringCount)
        assertEquals(1, merged.mutualPeerCount)
        assertEquals(0, merged.detectedPeerCount)
    }

    /** Invariant 4 for the counts: a peer that draws nothing is in neither of them. */
    @Test
    fun registeredPeerWithNoPresenceIsInNeitherCount() {
        val source = createSigilInput(3)
        assertTrue(addSigilPeer(source, "peer-a"))
        val alone = layoutSigil(source, 200.0, SigilGround.NONE)
        assertEquals(0, alone.peerCount)
        assertEquals(0, alone.mutualPeerCount)
        assertEquals(0, alone.detectedPeerCount)
        assertEquals(3, alone.windowCount)

        assertTrue(addSigilPresence(source, "peer-b", 0, 1))
        val withOne = layoutSigil(source, 200.0, SigilGround.NONE)
        assertEquals(1, withOne.peerCount)
        assertEquals(0, withOne.mutualPeerCount)
        assertEquals(1, withOne.detectedPeerCount)
    }

    /** Catches windowCount being served from the ring count, which differs as soon as W > 12. */
    @Test
    fun windowCountEchoesTheInputAndIsNotTheRingCount() {
        val w12 = layoutSigil(input(12, Triple("peer-a", 11, 1)), 200.0, SigilGround.NONE)
        assertEquals(12, w12.windowCount)
        assertEquals(12, w12.ringCount)
        assertEquals(1, w12.windowsPerRing)

        val w25 = layoutSigil(input(25, Triple("peer-a", 24, 1)), 200.0, SigilGround.NONE)
        assertEquals(25, w25.windowCount)
        assertEquals(9, w25.ringCount)
        assertEquals(3, w25.windowsPerRing)

        val wMax = layoutSigil(input(100_000, Triple("peer-a", 99_999, 1)), 200.0, SigilGround.NONE)
        assertEquals(100_000, wMax.windowCount)
        assertEquals(12, wMax.ringCount)
        assertEquals(8334, wMax.windowsPerRing)

        assertEquals(6, layoutSigil(createSigilInput(6), 60.0, SigilGround.NONE).windowCount)
    }

    /** Catches a failed layout echoing the window count it was handed instead of reporting nothing. */
    @Test
    fun failedLayoutReportsZeroForAllThreeCounts() {
        val valid = input(6, Triple("peer-a", 0, 2), Triple("peer-b", 1, 1))
        for (size in listOf(0.0, 24.999999, Double.NaN)) {
            val layout = layoutSigil(valid, size, SigilGround.NONE)
            assertEquals("invalid_size", layout.errorCode, "size $size")
            assertEquals(0, layout.mutualPeerCount, "size $size")
            assertEquals(0, layout.detectedPeerCount, "size $size")
            assertEquals(0, layout.windowCount, "size $size")
        }
        for (windowCount in listOf(-1, 0, 100_001)) {
            val layout = layoutSigil(createSigilInput(windowCount), 200.0, SigilGround.NONE)
            assertEquals("invalid_window_count", layout.errorCode, "W $windowCount")
            assertEquals(0, layout.mutualPeerCount, "W $windowCount")
            assertEquals(0, layout.detectedPeerCount, "W $windowCount")
            assertEquals(0, layout.windowCount, "W $windowCount")
        }
    }

    /** Invariant 2 for the counts: insertion order and a repeated entry never move them. */
    @Test
    fun countsAreOrderIndependentAndDeterministic() {
        val entries = listOf(
            Triple("peer-a", 0, 1), Triple("peer-a", 2, 2),
            Triple("peer-b", 1, 1), Triple("peer-b", 3, 1),
            Triple("peer-c", 0, 2),
            Triple("peer-d", 2, 1),
        )
        val forward = createSigilInput(4)
        entries.forEach { (key, window, presence) ->
            assertTrue(addSigilPresence(forward, key, window, presence), "rejected $key/$window/$presence")
        }
        val reverse = createSigilInput(4)
        entries.reversed().forEach { (key, window, presence) ->
            assertTrue(addSigilPresence(reverse, key, window, presence), "rejected $key/$window/$presence")
        }
        // A repeat resolving to the same max must not count peer-b twice.
        assertTrue(addSigilPresence(reverse, "peer-b", 1, 1))

        val a = layoutSigil(forward, 200.0, SigilGround.DISC)
        assertEquals(4, a.peerCount)
        assertEquals(2, a.mutualPeerCount)
        assertEquals(2, a.detectedPeerCount)
        sameLayout(a, layoutSigil(reverse, 200.0, SigilGround.DISC))
        sameLayout(a, layoutSigil(forward, 200.0, SigilGround.DISC))
    }

    // --- Accessor surface ----------------------------------------------------

    @Test
    fun accessorsReturnNullOutOfRange() {
        val layout = layoutSigil(input(4, *goldenEntries), 200.0, SigilGround.DISC)
        assertNull(layout.primitiveAt(-1))
        assertNull(layout.primitiveAt(layout.primitiveCount))
        assertNull(layout.peerAt(-1))
        assertNull(layout.peerAt(layout.peerCount))
        assertEquals(18, layout.primitiveCount)
        assertEquals(200.0, layout.size)
        assertEquals(4, createSigilInput(4).windowCount)
    }
}

package org.levarac.beid.ui.designsystem

import android.content.res.Resources
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import kotlin.math.cos
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.shared.sigil.SigilGround
import org.levarac.beid.shared.sigil.addSigilPresence
import org.levarac.beid.shared.sigil.createSigilInput
import org.levarac.beid.shared.sigil.layoutSigil
import org.levarac.beid.ui.theme.BeidSize
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Port of iOS `SensingRadarViewTests` (draft integration/ios-1.1.1), plus the
 * Android-only cross-check of the mirrored FNV-1a angle against shared's
 * public `layoutSigil` output.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SensingRadarProjectionTest {
    private val resources: Resources get() = ApplicationProvider.getApplicationContext<android.content.Context>().resources
    private val size = 362.0

    @Test
    fun fieldTokensMatchTheMeasuredFigmaValues() {
        assertEquals(362.dp, BeidSize.radarField)
        assertEquals(48.dp, BeidSize.radarCoreSeparation)
        assertEquals(38.dp, BeidSize.radarCore)
        assertEquals(8.dp, BeidSize.radarCenterDot)
        assertEquals(8.dp, BeidSize.radarDetectedNode)
        assertEquals(1.5.dp, BeidSize.radarDetectedNodeStroke)
        assertEquals(1.dp, BeidSize.hairline)
    }

    @Test
    fun hashMatchesFrozenSigilVectors() {
        assertEquals(0xb1df888881737297uL, SensingRadarProjection.stablePeerHash("peer-a"))
        assertEquals(0xaf63dc4c8601ec8cuL, SensingRadarProjection.stablePeerHash("a"))
        assertEquals(0xee9ee2b5c854ef87uL, SensingRadarProjection.stablePeerHash("日本語"))
        assertEquals(71, SensingRadarProjection.angleDegrees("peer-a"))
        assertEquals(162, SensingRadarProjection.angleDegrees("peer-b"))
        assertEquals(253, SensingRadarProjection.angleDegrees("peer-c"))
    }

    /**
     * The mirror must agree with shared's own (internal) `sigilPeerHash`, read
     * through its public output: a single-peer layout's base angle.
     */
    @Test
    fun angleAgreesWithSharedSigilBaseAngle() {
        val ids = listOf(
            "peer-a", "peer-b", "peer-c", "a", "日本語", "private-peer-identifier",
            "0123456789abcdef0123456789abcdef", "Ünïcödé-👋", "x".repeat(200),
        )
        for (id in ids) {
            val input = createSigilInput(1)
            assertTrue(id, addSigilPresence(input, id, 0, 1))
            val layout = layoutSigil(input, 200.0, SigilGround.NONE)
            assertTrue(id, layout.isSuccess)
            assertEquals(1, layout.peerCount)
            assertEquals(id, layout.peerAt(0)!!.baseAngleDegrees, SensingRadarProjection.angleDegrees(id))
        }
    }

    @Test
    fun ringPathsMatchMeasuredFigmaDiameters() {
        val diameters = SensingRadarProjection.ringDiameters(size)
        assertEquals(3, diameters.size)
        assertEquals(133.22, diameters[0], 0.001)
        assertEquals(233.12, diameters[1], 0.001)
        assertEquals(333.04, diameters[2], 0.001)

        val half = SensingRadarProjection.ringDiameters(size / 2)
        assertEquals(66.61, half[0], 0.001)
        assertEquals(116.56, half[1], 0.001)
        assertEquals(166.52, half[2], 0.001)
    }

    /** inner = 48 / 2 + 14 = 38; outer = 362 / 2 - 12 = 169; -40 and -100 dBm are the anchors. */
    @Test
    fun radiusLiteralsAtTheFigmaField() {
        assertEquals(169.0, SensingRadarProjection.radius(null, size), 1e-9)
        assertEquals(38.0, SensingRadarProjection.radius(-40.0, size), 1e-9)
        assertEquals(38.0, SensingRadarProjection.radius(-20.0, size), 1e-9)
        assertEquals(103.5, SensingRadarProjection.radius(-70.0, size), 1e-9)
        assertEquals(169.0, SensingRadarProjection.radius(-120.0, size), 1e-9)
        assertEquals(19.0, SensingRadarProjection.radius(-40.0, size / 2), 1e-9)
        assertEquals(84.5, SensingRadarProjection.radius(null, size / 2), 1e-9)
    }

    @Test
    fun angleAndDirectionStayFixedAcrossSignalChanges() {
        val first = SensingRadarProjection.project(listOf(SensingRadarPeer("peer-a", null)), size).nodes.single()
        val later = SensingRadarProjection.project(listOf(SensingRadarPeer("peer-a", -50.0)), size).nodes.single()
        assertEquals(first.angleDegrees, later.angleDegrees)
        assertTrue(later.radius < first.radius)
        val center = size / 2
        assertEquals((first.x - center) / first.radius, (later.x - center) / later.radius, 1e-6)
        assertEquals((first.y - center) / first.radius, (later.y - center) / later.radius, 1e-6)
    }

    /** Angle 0 points up and runs clockwise, as on iOS (x = c + sin, y = c - cos). */
    @Test
    fun nodePointLiteralForPeerA() {
        val node = SensingRadarProjection.project(listOf(SensingRadarPeer("peer-a", null)), size).nodes.single()
        val radians = 71 * Math.PI / 180
        assertEquals("peer-a", node.peerId)
        assertEquals(169.0, node.radius, 1e-9)
        assertEquals(181 + sin(radians) * 169, node.x, 1e-9)
        assertEquals(181 - cos(radians) * 169, node.y, 1e-9)
        assertEquals(340.79, node.x, 0.01)
        assertEquals(125.98, node.y, 0.01)
    }

    @Test
    fun unmeasuredAndNeverMeasuredSentinelStayOutermost() {
        val outer = SensingRadarProjection.radius(null, size)
        assertEquals(outer, SensingRadarProjection.radius(0.0, size), 0.0)
        assertEquals(outer, SensingRadarProjection.radius(Double.POSITIVE_INFINITY, size), 0.0)
        assertEquals(outer, SensingRadarProjection.radius(Double.NEGATIVE_INFINITY, size), 0.0)
        assertEquals(outer, SensingRadarProjection.radius(Double.NaN, size), 0.0)
        assertEquals(outer, SensingRadarProjection.radius(5.0, size), 0.0)
        assertEquals(outer, SensingRadarProjection.radius(-100.0, size), 0.0)
        assertTrue(SensingRadarProjection.radius(-70.0, size) < outer)
        assertTrue(SensingRadarProjection.radius(-40.0, size) < SensingRadarProjection.radius(-70.0, size))
    }

    @Test
    fun everyEdgeRunsFromMeToExactlyOnePeer() {
        val peers = listOf(
            SensingRadarPeer("peer-a", null),
            SensingRadarPeer("peer-b", -55.0),
            SensingRadarPeer("peer-c", -90.0),
        )
        val result = SensingRadarProjection.project(peers, size)
        assertEquals(peers.size, result.nodes.size)
        assertEquals(peers.size, result.edges.size)
        assertEquals(peers.map { it.id }.toSet(), result.edges.map { it.peerId }.toSet())
        for (edge in result.edges) {
            val node = result.nodes.single { it.peerId == edge.peerId }
            assertEquals(size / 2, edge.fromX, 0.0)
            assertEquals(size / 2, edge.fromY, 0.0)
            assertEquals(node.x, edge.toX, 0.0)
            assertEquals(node.y, edge.toY, 0.0)
            assertFalse(edge.toX == size / 2 && edge.toY == size / 2)
        }
    }

    @Test
    fun detectingOptionSuppressesEdgesButKeepsAllNodes() {
        val peers = listOf(SensingRadarPeer("peer-a", null), SensingRadarPeer("peer-b", -70.0))
        val detecting = SensingRadarProjection.project(peers, size, showsEdges = false)
        val sensing = SensingRadarProjection.project(peers, size, showsEdges = true)
        assertEquals(sensing.nodes, detecting.nodes)
        assertTrue(detecting.edges.isEmpty())
        assertEquals(peers.size, sensing.edges.size)
    }

    @Test
    fun noPeersProjectsNothing() {
        val empty = SensingRadarProjection.project(emptyList(), size)
        assertTrue(empty.nodes.isEmpty())
        assertTrue(empty.edges.isEmpty())
        assertEquals("0 devices heard", SensingRadarProjection.accessibilitySummary(emptyList(), 0, 0, resources))
    }

    /** Draft integration/ios-1.1.1: mutuality and windows are not spoken. */
    @Test
    fun accessibilitySummaryOmitsMutualCountsAndPrivateIdentifiers() {
        val privateId = "private-peer-identifier"
        val peers = listOf(SensingRadarPeer(privateId, null), SensingRadarPeer("other", -60.0))
        val zero = SensingRadarProjection.accessibilitySummary(peers, mutualDeviceCount = 0, observedWindowCount = 6, resources)
        val mutual = SensingRadarProjection.accessibilitySummary(peers, mutualDeviceCount = 1, observedWindowCount = 6, resources)
        assertEquals("2 devices heard", zero)
        assertEquals("2 devices heard", mutual)
        assertFalse(zero.contains(privateId))
        assertFalse(mutual.contains(privateId))
        assertFalse(mutual.contains("other"))
        assertNotEquals("", zero)
    }
}

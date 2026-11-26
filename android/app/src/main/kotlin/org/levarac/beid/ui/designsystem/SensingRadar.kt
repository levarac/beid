package org.levarac.beid.ui.designsystem

import android.content.res.Resources
import androidx.compose.animation.core.animateOffsetAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin
import org.levarac.beid.R
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidOpacity
import org.levarac.beid.ui.theme.BeidSize
import org.levarac.beid.ui.theme.BeidTheme

/*
 * The sensing-time radar: port of iOS `ios/Beid/Views/SensingRadarView.swift`
 * as on release/1.1.0 (whose summary speaks only the number of devices heard
 * in the last five minutes).
 *
 * Distances are display-only and never reach a record or submission path.
 * Peer identifiers are only used to place a node; they are never shown or
 * spoken.
 */

/**
 * One display-only detected peer. [id] must be the normalized, session-stable
 * display id, not a rotating proximity id. [signalDbm] is null while the peer
 * is unmeasured; every detected peer is supplied, measured or not.
 * [isDimmed] marks a retained peer that has not been heard recently (iOS
 * #855); it only lowers the node's opacity.
 */
data class SensingRadarPeer(val id: String, val signalDbm: Double?, val isDimmed: Boolean = false)

/** A projected peer, in the field's dp space (origin top-left). */
data class SensingRadarNode(
    val peerId: String,
    val x: Double,
    val y: Double,
    val angleDegrees: Int,
    val radius: Double,
    val isDimmed: Boolean,
)

/** An edge always runs from the centre ("me") to one peer; there is no peer-to-peer edge. */
data class SensingRadarEdge(
    val peerId: String,
    val fromX: Double,
    val fromY: Double,
    val toX: Double,
    val toY: Double,
)

data class SensingRadarLayout(val nodes: List<SensingRadarNode>, val edges: List<SensingRadarEdge>)

/**
 * Provisional signal mapping, as on iOS: Figma fixes the drawing dimensions
 * ([BeidSize]); real-device observation must settle these dBm anchors.
 */
private object SensingRadarMetrics {
    const val CORE_CLEARANCE = 14.0
    const val OUTER_INSET = 12.0
    const val STRONG_SIGNAL_DBM = -40.0
    const val WEAK_SIGNAL_DBM = -100.0
}

/** Pure projection for the renderer and the geometry tests. */
object SensingRadarProjection {
    private const val FNV_OFFSET_BASIS: ULong = 0xcbf29ce484222325uL
    private const val FNV_PRIME: ULong = 0x100000001b3uL

    fun scale(size: Double): Double = size / BeidSize.radarField.value

    /** The three ring-path diameters, scaled with the field. At 362 they are 133.22, 233.12 and 333.04. */
    fun ringDiameters(size: Double): List<Double> {
        val scale = scale(size)
        return listOf(BeidSize.radarRingInner, BeidSize.radarRingMiddle, BeidSize.radarRingOuter)
            .map { it.value.toDouble() * scale }
    }

    /**
     * Draws progress only for an observed window, using its actual clock
     * boundary so a late first detection does not start a new five minutes.
     * Null without an observed window, for a non-positive [windowDuration], or
     * when [secondsSince1970] lies outside that window; otherwise grows
     * linearly from the inner ring's diameter to the outer ring's, in the
     * field's dp space (iOS release/1.1.0).
     */
    fun recordedWindowMarkDiameter(
        observedWindowIndex: Long?,
        secondsSince1970: Double,
        windowDuration: Double,
        size: Double,
    ): Double? {
        if (observedWindowIndex == null || windowDuration <= 0) return null
        val elapsed = secondsSince1970 - observedWindowIndex.toDouble() * windowDuration
        if (elapsed < 0 || elapsed > windowDuration) return null
        val scale = scale(size)
        val inner = BeidSize.radarRingInner.value.toDouble() * scale
        val outer = BeidSize.radarRingOuter.value.toDouble() * scale
        return inner + (outer - inner) * (elapsed / windowDuration)
    }

    /**
     * FNV-1a 64 over UTF-8, mirroring shared's internal `sigilPeerHash`
     * (SigilLayout.kt) exactly as iOS does. Cross-checked against shared's
     * public `SigilPeerAngle.baseAngleDegrees` by SensingRadarProjectionTest.
     */
    fun stablePeerHash(peerId: String): ULong {
        var hash = FNV_OFFSET_BASIS
        for (byte in peerId.encodeToByteArray()) {
            hash = (hash xor byte.toUByte().toULong()) * FNV_PRIME
        }
        return hash
    }

    /** Whole degrees, 0 pointing up, clockwise. */
    fun angleDegrees(peerId: String): Int = (stablePeerHash(peerId) % 360uL).toInt()

    /**
     * Stronger measured signals sit nearer the core; an unmeasured peer sits
     * outermost. 0 dBm, a positive value and any non-finite value are treated
     * as unmeasured, so a malformed producer cannot turn a never-measured
     * sentinel into a claim of proximity.
     */
    fun radius(signalDbm: Double?, size: Double): Double {
        val scale = scale(size)
        val inner = (BeidSize.radarCoreSeparation.value / 2 + SensingRadarMetrics.CORE_CLEARANCE) * scale
        val outer = max(inner, size / 2 - SensingRadarMetrics.OUTER_INSET * scale)
        if (signalDbm == null || !signalDbm.isFinite() || signalDbm >= 0) return outer
        val fraction = ((SensingRadarMetrics.STRONG_SIGNAL_DBM - signalDbm) /
            (SensingRadarMetrics.STRONG_SIGNAL_DBM - SensingRadarMetrics.WEAK_SIGNAL_DBM))
            .coerceIn(0.0, 1.0)
        return inner + (outer - inner) * fraction
    }

    fun project(peers: List<SensingRadarPeer>, size: Double, showsEdges: Boolean = true): SensingRadarLayout {
        val center = size / 2
        val nodes = peers.map { peer ->
            val angle = angleDegrees(peer.id)
            val radians = angle * PI / 180
            val radius = radius(peer.signalDbm, size)
            SensingRadarNode(
                peerId = peer.id,
                x = center + sin(radians) * radius,
                y = center - cos(radians) * radius,
                angleDegrees = angle,
                radius = radius,
                isDimmed = peer.isDimmed,
            )
        }
        // 05a/05a2/05a3 show detected nodes without edges.
        val edges = if (showsEdges) {
            nodes.map { SensingRadarEdge(it.peerId, center, center, it.x, it.y) }
        } else {
            emptyList()
        }
        return SensingRadarLayout(nodes, edges)
    }

    /**
     * iOS release/1.1.0 (`radar.accessibility.devicesHeard`): nearby
     * observations do not establish whether another phone heard this one, so
     * only the number heard is spoken. The counts are accepted, as on iOS, but
     * deliberately unused. Peer identifiers are never spoken.
     */
    @Suppress("UNUSED_PARAMETER")
    fun accessibilitySummary(
        peers: List<SensingRadarPeer>,
        mutualDeviceCount: Int,
        observedWindowCount: Int,
        resources: Resources,
    ): String = resources.getQuantityString(R.plurals.radar_accessibility_devices_heard, peers.size, peers.size)
}

/**
 * A reusable sensing-time radar. [peers] must include unmeasured detections.
 * [mutualDeviceCount] and [observedWindowCount] come from the session
 * aggregate; neither changes node styling, and (iOS release/1.1.0) neither is
 * spoken. The field defaults to the Figma 05 diameter.
 * [recordedWindowMarkDiameter], when non-null, strokes a hairline progress
 * circle of that diameter (see
 * [SensingRadarProjection.recordedWindowMarkDiameter]).
 */
object SensingRadar {
    /** iOS `accessibilityIdentifier("sensing.radar")`. */
    const val TEST_TAG = "sensing.radar"

    /**
     * iOS `DS.Motion.standard`, `spring(response: 0.35, dampingFraction: 1)`:
     * SwiftUI's stiffness is (2π / response)² at unit mass. Compose scales
     * animations by the system animator duration scale, which is how the
     * "Remove animations" setting applies (iOS: Reduce Motion).
     */
    private const val SPRING_RESPONSE_SECONDS = 0.35
    private val nodeSpring = spring<Offset>(
        dampingRatio = 1f,
        stiffness = ((2 * PI / SPRING_RESPONSE_SECONDS) * (2 * PI / SPRING_RESPONSE_SECONDS)).toFloat(),
    )

    @Composable
    operator fun invoke(
        peers: List<SensingRadarPeer>,
        mutualDeviceCount: Int,
        observedWindowCount: Int,
        modifier: Modifier = Modifier,
        showsEdges: Boolean = true,
        size: Dp = BeidSize.radarField,
        recordedWindowMarkDiameter: Dp? = null,
    ) {
        val field = size.value.toDouble()
        val projection = remember(peers, field, showsEdges) { SensingRadarProjection.project(peers, field, showsEdges) }
        val scale = SensingRadarProjection.scale(field).toFloat()
        val rings = remember(field) { SensingRadarProjection.ringDiameters(field) }
        val points = projection.nodes.map { node ->
            key(node.peerId) {
                animateOffsetAsState(Offset(node.x.toFloat(), node.y.toFloat()), nodeSpring, label = "radarNode").value
            }
        }
        val summary = SensingRadarProjection.accessibilitySummary(
            peers,
            mutualDeviceCount,
            observedWindowCount,
            LocalContext.current.resources,
        )
        val colors = BeidTheme.colors
        val hairline = BeidSize.hairline.value

        Canvas(
            // The caller's own tag, if any, is outermost and therefore wins.
            modifier
                .testTag(TEST_TAG)
                .size(size)
                .background(colors.textPrimary)
                .clearAndSetSemantics { contentDescription = summary },
        ) {
            scale(scale = density, pivot = Offset.Zero) {
                val center = Offset(field.toFloat() / 2, field.toFloat() / 2)
                rings.forEach { diameter ->
                    drawCircle(colors.strokeHairlineOnInk, diameter.toFloat() / 2, center, style = Stroke(hairline))
                }
                // iOS order: rings, recorded-window mark, edges, core, nodes.
                if (recordedWindowMarkDiameter != null) {
                    drawCircle(
                        colors.labelOnActionPrimary,
                        recordedWindowMarkDiameter.value / 2,
                        center,
                        style = Stroke(hairline),
                    )
                }
                if (projection.edges.isNotEmpty()) {
                    points.forEach { point -> drawLine(colors.strokeHairlineOnInk, center, point, hairline) }
                }
                // Figma 05: 48 ink separation, 38 white disc, 8 ink centre dot, scaled with the field.
                drawCircle(colors.textPrimary, BeidSize.radarCoreSeparation.value * scale / 2, center)
                drawCircle(colors.surfaceCanvas, BeidSize.radarCore.value * scale / 2, center)
                drawCircle(colors.textPrimary, BeidSize.radarCenterDot.value * scale / 2, center)
                // Detected-only mark: ink fill, idle outline. No node gets mutual styling:
                // the aggregate mutual count does not identify which peer was mutual.
                val nodeRadius = BeidSize.radarDetectedNode.value * scale / 2
                val nodeStrokeWidth = BeidSize.radarDetectedNodeStroke.value * scale
                val nodeStroke = Stroke(nodeStrokeWidth)
                projection.nodes.zip(points).forEach { (node, point) ->
                    // iOS applies `.opacity` to the whole glyph, so a silent node is
                    // composited as one layer rather than fading fill and outline separately.
                    // Edges are not dimmed, as on iOS.
                    if (node.isDimmed) {
                        drawContext.canvas.saveLayer(
                            Rect(point, nodeRadius + nodeStrokeWidth),
                            Paint().apply { alpha = BeidOpacity.radarSilentNode },
                        )
                    }
                    drawCircle(colors.textPrimary, nodeRadius, point)
                    drawCircle(colors.graphNodeIdle, nodeRadius, point, style = nodeStroke)
                    if (node.isDimmed) drawContext.canvas.restore()
                }
            }
        }
    }
}

@Preview(name = "Radar — 6 peers, edges")
@Composable
private fun SensingRadarPreview() = BeidAppTheme {
    SensingRadar(
        peers = listOf(
            SensingRadarPeer("peer-a", null),
            SensingRadarPeer("peer-b", -45.0),
            SensingRadarPeer("peer-c", -60.0),
            SensingRadarPeer("peer-d", -75.0),
            SensingRadarPeer("peer-e", -95.0),
            SensingRadarPeer("peer-f", null),
        ),
        mutualDeviceCount = 0,
        observedWindowCount = 6,
    )
}

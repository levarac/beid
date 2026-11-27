package org.levarac.beid.ui.designsystem

import android.content.res.Resources
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.hideFromAccessibility
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import org.levarac.beid.R
import org.levarac.beid.shared.sigil.SigilGround
import org.levarac.beid.shared.sigil.SigilInput
import org.levarac.beid.shared.sigil.SigilLayout
import org.levarac.beid.shared.sigil.SigilPrimitiveKind
import org.levarac.beid.shared.sigil.addSigilPresence
import org.levarac.beid.shared.sigil.createSigilInput
import org.levarac.beid.shared.sigil.layoutSigil
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidColorScheme
import org.levarac.beid.ui.theme.BeidSize
import org.levarac.beid.ui.theme.BeidTheme

/*
 * The Proof 紋様 (Sigil) drawing component: port of iOS
 * `ios/Beid/DesignSystem/SigilView.swift` (beid#633), including the device-
 * record summary of the draft integration/ios-1.1.1.
 *
 * Ownership. shared's `layoutSigil` (shared/.../sigil/SigilLayout.kt) owns
 * every number: angles, radii, stroke widths, the full/mini variant, the ring
 * count and the draw order. This file owns only which colour paints a mark and
 * the Compose calls that put it on screen. No coordinate, radius or width is
 * computed here: a primitive's Doubles are carried verbatim into a
 * [SigilDrawCommand] and only converted to Float at the draw call. The layout
 * is in dp; the renderer applies one uniform dp-to-px canvas scale instead of
 * multiplying any value. A geometry change belongs in SigilLayout.kt.
 */

/**
 * The palette role a Sigil mark is painted with (DESIGN.md §5): [Ink] is
 * `textPrimary` (marks on the page, and the ground itself); [OnInk] is
 * `surfaceCanvas` (marks that sit on the filled ink disc or on an ink page).
 */
enum class SigilInkRole {
    Ink,
    OnInk,
    ;

    fun color(colors: BeidColorScheme): Color = when (this) {
        Ink -> colors.textPrimary
        OnInk -> colors.surfaceCanvas
    }
}

/**
 * The page a Sigil sits on (beid#653 OD-6). A Sigil with no ground on an ink
 * page must draw its marks in `bg`. A colour decision only: it moves no geometry.
 */
enum class SigilPage { Canvas, Ink }

/** The drawing operation a `SigilPrimitiveKind` names in SigilLayout.kt's own documentation. */
enum class SigilMarkShape { FilledCircle, StrokedCircle, Segment }

/**
 * One primitive, transported into drawing terms, in the layout's dp space.
 * Carries no kind: the kind has already chosen the shape and the role.
 */
sealed interface SigilDrawCommand {
    val role: SigilInkRole

    data class Fill(
        val centerX: Double,
        val centerY: Double,
        val radius: Double,
        override val role: SigilInkRole,
    ) : SigilDrawCommand

    data class StrokeCircle(
        val centerX: Double,
        val centerY: Double,
        val radius: Double,
        val lineWidth: Double,
        override val role: SigilInkRole,
    ) : SigilDrawCommand

    data class StrokeLine(
        val fromX: Double,
        val fromY: Double,
        val toX: Double,
        val toY: Double,
        val lineWidth: Double,
        override val role: SigilInkRole,
    ) : SigilDrawCommand
}

/** The pure half of the component: shared layout in, ordered draw commands out. */
object SigilDrawing {

    /**
     * Exhaustive over the shared enum, so a new kind is a compile error here
     * rather than iOS's silently dropped `nil` (Swift Export gives iOS no
     * exhaustive switch).
     */
    fun markShape(kind: SigilPrimitiveKind): SigilMarkShape = when (kind) {
        SigilPrimitiveKind.GROUND_DISC -> SigilMarkShape.FilledCircle
        SigilPrimitiveKind.GROUND_OUTLINE -> SigilMarkShape.StrokedCircle
        SigilPrimitiveKind.RING -> SigilMarkShape.StrokedCircle
        SigilPrimitiveKind.DETECTED_LINE -> SigilMarkShape.Segment
        SigilPrimitiveKind.MUTUAL_LINE -> SigilMarkShape.Segment
        SigilPrimitiveKind.DETECTED_DOT -> SigilMarkShape.FilledCircle
        SigilPrimitiveKind.MUTUAL_DOT -> SigilMarkShape.FilledCircle
        SigilPrimitiveKind.CENTER_DOT -> SigilMarkShape.FilledCircle
    }

    /**
     * The ground itself is always ink. A mark is bg when it sits on ink (the
     * filled disc, or an ink page), and ink otherwise.
     */
    fun inkRole(kind: SigilPrimitiveKind, ground: SigilGround, page: SigilPage = SigilPage.Canvas): SigilInkRole =
        when (kind) {
            SigilPrimitiveKind.GROUND_DISC, SigilPrimitiveKind.GROUND_OUTLINE -> SigilInkRole.Ink
            SigilPrimitiveKind.RING,
            SigilPrimitiveKind.DETECTED_LINE,
            SigilPrimitiveKind.MUTUAL_LINE,
            SigilPrimitiveKind.DETECTED_DOT,
            SigilPrimitiveKind.MUTUAL_DOT,
            SigilPrimitiveKind.CENTER_DOT,
            -> if (ground == SigilGround.DISC || page == SigilPage.Ink) SigilInkRole.OnInk else SigilInkRole.Ink
        }

    /**
     * One command per primitive, in `primitiveAt` index order. The order is
     * the draw order and is load-bearing (every mutual layer comes after its
     * detected counterpart), so never sort, group or de-duplicate it. A failed
     * layout has nothing to draw and yields no commands.
     */
    fun commands(layout: SigilLayout, ground: SigilGround, page: SigilPage = SigilPage.Canvas): List<SigilDrawCommand> {
        if (!layout.isSuccess) return emptyList()
        return (0 until layout.primitiveCount).map { index ->
            val primitive = checkNotNull(layout.primitiveAt(index)) { "primitive $index of ${layout.primitiveCount}" }
            val role = inkRole(primitive.kind, ground, page)
            when (markShape(primitive.kind)) {
                SigilMarkShape.FilledCircle -> SigilDrawCommand.Fill(primitive.x, primitive.y, primitive.radius, role)
                SigilMarkShape.StrokedCircle -> SigilDrawCommand.StrokeCircle(
                    primitive.x, primitive.y, primitive.radius, primitive.lineWidth, role,
                )
                SigilMarkShape.Segment -> SigilDrawCommand.StrokeLine(
                    primitive.x, primitive.y, primitive.x2, primitive.y2, primitive.lineWidth, role,
                )
            }
        }
    }

    /**
     * Spoken in place of the Sigil (DESIGN.md §13): "M mutual, D detected,
     * window W", from the three counts `SigilLayout` exports for it. iOS key
     * `sigil.accessibilitySummary`.
     */
    fun accessibilitySummary(layout: SigilLayout, resources: Resources): String =
        resources.getString(
            R.string.sigil_accessibility_summary,
            layout.mutualPeerCount,
            layout.detectedPeerCount,
            layout.windowCount,
        )

    /**
     * A device record's summary (iOS draft integration/ios-1.1.1,
     * `sigil.record.accessibilitySummary`): mutuality is decided off device,
     * so it is never spoken as a measured count.
     */
    fun recordAccessibilitySummary(layout: SigilLayout, resources: Resources): String =
        resources.getString(
            R.string.sigil_record_accessibility_summary,
            layout.detectedPeerCount,
            layout.windowCount,
        )

    /**
     * A failed layout drew nothing, so speaking "0 mutual, 0 detected,
     * window 0" over an empty square would state something false about the
     * user's data. It is skipped instead.
     */
    fun isAccessibilityHidden(layout: SigilLayout): Boolean = !layout.isSuccess
}

/**
 * Renders commands in the layout's dp space. Strokes keep Compose's default
 * butt cap: a round cap would extend a segment past the layout's endpoints.
 */
private fun DrawScope.drawSigilCommands(commands: List<SigilDrawCommand>, colors: BeidColorScheme) {
    scale(scale = density, pivot = Offset.Zero) {
        for (command in commands) {
            val color = command.role.color(colors)
            when (command) {
                is SigilDrawCommand.Fill -> drawCircle(
                    color = color,
                    radius = command.radius.toFloat(),
                    center = Offset(command.centerX.toFloat(), command.centerY.toFloat()),
                )
                is SigilDrawCommand.StrokeCircle -> drawCircle(
                    color = color,
                    radius = command.radius.toFloat(),
                    center = Offset(command.centerX.toFloat(), command.centerY.toFloat()),
                    style = Stroke(width = command.lineWidth.toFloat()),
                )
                is SigilDrawCommand.StrokeLine -> drawLine(
                    color = color,
                    start = Offset(command.fromX.toFloat(), command.fromY.toFloat()),
                    end = Offset(command.toX.toFloat(), command.toY.toFloat()),
                    strokeWidth = command.lineWidth.toFloat(),
                )
            }
        }
    }
}

/**
 * Draws one Sigil, full or mini: the variant is the shared layout's choice
 * from [size], so this composable never branches on how big it is. It takes
 * the input rather than a layout so the geometry and the frame can never
 * disagree about [size].
 *
 * Accessibility: one element whose description is the summary
 * ([isDeviceRecord] selects the device-record sentence); hidden when the
 * layout failed and nothing was drawn.
 */
@Composable
fun BeidSigil(
    input: SigilInput,
    size: Dp,
    ground: SigilGround,
    modifier: Modifier = Modifier,
    page: SigilPage = SigilPage.Canvas,
    isDeviceRecord: Boolean = false,
) {
    // Not remembered: SigilInput is a mutable accumulator (a live session keeps
    // adding to the same instance), so a cache keyed on its identity would go
    // stale. iOS likewise lays out on every body evaluation.
    val layout = layoutSigil(input, size.value.toDouble(), ground)
    val commands = SigilDrawing.commands(layout, ground, page)
    val resources = LocalContext.current.resources
    val summary = if (isDeviceRecord) {
        SigilDrawing.recordAccessibilitySummary(layout, resources)
    } else {
        SigilDrawing.accessibilitySummary(layout, resources)
    }
    val hidden = SigilDrawing.isAccessibilityHidden(layout)
    val colors = BeidTheme.colors
    Canvas(
        modifier = modifier
            .size(size)
            .clearAndSetSemantics {
                if (hidden) hideFromAccessibility() else contentDescription = summary
            },
    ) {
        drawSigilCommands(commands, colors)
    }
}

/**
 * Preview and review-screenshot fixture, built through the same shared calls
 * production code uses (port of iOS `SigilPreviewInputFactory`). Fixture data
 * only: presence 2 (mutual) does not exist on a device today, so this is the
 * only place the mutual marks can be seen. Nothing in production reads it.
 */
internal object SigilPreviewInputFactory {
    fun sample(): SigilInput {
        val windowCount = 12
        val input = createSigilInput(windowCount)
        for (peer in 0 until 9) {
            for (window in 0 until windowCount) {
                if ((peer + window) % 3 == 0) continue
                check(addSigilPresence(input, "preview-peer-$peer", window, if ((peer + window) % 4 == 0) 2 else 1))
            }
        }
        return input
    }
}

// Previews: the contexts #633 names, from fixture input only. Documentation,
// not wiring; production screens draw through RecordSigilSlot.

@Preview(name = "Proof Collected — 290, disc")
@Composable
private fun SigilProofCollectedPreview() = BeidAppTheme {
    BeidSigil(SigilPreviewInputFactory.sample(), 290.dp, SigilGround.DISC, Modifier.padding(16.dp))
}

@Preview(name = "Proof Detail — disc")
@Composable
private fun SigilProofDetailPreview() = BeidAppTheme {
    BeidSigil(SigilPreviewInputFactory.sample(), BeidSize.proofDetailSigil, SigilGround.DISC, Modifier.padding(16.dp))
}

@Preview(name = "Welcome hero — outline, line art")
@Composable
private fun SigilOutlinePreview() = BeidAppTheme {
    BeidSigil(SigilPreviewInputFactory.sample(), 200.dp, SigilGround.OUTLINE, Modifier.padding(16.dp))
}

@Preview(name = "Sensing verified — no ground")
@Composable
private fun SigilNoGroundPreview() = BeidAppTheme {
    BeidSigil(SigilPreviewInputFactory.sample(), 200.dp, SigilGround.NONE, Modifier.padding(16.dp))
}

@Preview(name = "Mini — 60, no ground")
@Composable
private fun SigilMiniPreview() = BeidAppTheme {
    BeidSigil(SigilPreviewInputFactory.sample(), 60.dp, SigilGround.NONE, Modifier.padding(16.dp))
}

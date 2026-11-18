package org.levarac.beid.ui.designsystem

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import org.levarac.beid.ui.theme.BeidTheme

/**
 * Custom illustrations reproducing three of iOS's four
 * `ios/Beid/DesignSystem/Illustrations.xcassets` SVG assets, drawn with
 * [BeidTheme.colors] tokens. iOS #632 removed the dark SVG variants; the app
 * has a single appearance. The iOS SVGs still carry their pre-Flat 2b hex
 * colors, which no longer match a token — see each glyph's note. The fourth iOS asset, `encounter-field-empty`, is
 * intentionally NOT ported here — its only iOS call site is
 * `CollectionHomeView`'s empty state, which is beid#337 and was withdrawn
 * from this slice by the PM; porting it now would have no caller.
 *
 * **Reproduction, not import.** A VectorDrawable port would have a
 * one-to-one, diffable correspondence to the iOS SVG file. This is instead
 * a from-scratch [Canvas] redraw of the same primitives: if the iOS SVG
 * changes, nothing here goes stale automatically — a human has to notice
 * and re-transcribe these constants by hand. This is a deliberate,
 * accepted cost (see the beid#338 PR description), chosen because every
 * source SVG here is only circle/line primitives (no bezier paths, so no
 * arc-flag transcription risk), and redrawing with a theme token keeps
 * raw colors out of composables.
 *
 * All coordinates below are transcribed directly from each source SVG's
 * `viewBox="0 0 200 200"`. Each [Canvas] scales by `s = size.minDimension /
 * ViewBoxSize` and multiplies every transcribed coordinate/stroke-width by
 * `s`, so the drawing fills whatever box the caller's [Canvas] modifier
 * gives it. `Modifier.fillMaxSize(0.68f)` mirrors iOS's `BeidGlyph`, whose
 * `.padding(size * 0.16)` on all four sides leaves the same 68%-of-box
 * drawing area (`1 - 2 * 0.16 = 0.68`).
 */
private const val ViewBoxSize = 200f

/** A transcribed SVG `<line x1 y1 x2 y2>` in view-box units, pre-scale. */
private data class Segment(val x1: Float, val y1: Float, val x2: Float, val y2: Float)

/**
 * Ports iOS's `welcome-mark` illustration
 * (`ios/Beid/DesignSystem/Illustrations.xcassets/welcome-mark.imageset/welcome-mark.svg`
 * — a compass/dial mark. Color: [BeidTheme.colors.actionPrimary] (Library
 * `ink`, `#0B0B0F`; the iOS SVG still uses the pre-Flat 2b `#2A2E33`). Wired into `WelcomeScreen` via
 * `BeidStateScreen`'s `contentSlot`.
 */
private object WelcomeMarkGeometry {
    const val Center = 100f
    const val OuterRingRadius = 70f
    const val OuterRingStrokeWidth = 2f
    const val InnerRingRadius = 44f
    const val InnerRingStrokeWidth = 1f
    const val InnerRingAlpha = 0.35f
    const val CardinalTickStrokeWidth = 2f
    const val MinorTickStrokeWidth = 1.5f
    const val NeedleStrokeWidth = 2.5f
    const val PivotRadius = 4f

    // Cardinal ticks (longer).
    val cardinalTicks = listOf(
        Segment(100f, 30f, 100f, 42f),
        Segment(100f, 170f, 100f, 158f),
        Segment(30f, 100f, 42f, 100f),
        Segment(170f, 100f, 158f, 100f),
    )

    // Minor ticks, every 30 degrees.
    val minorTicks = listOf(
        Segment(135f, 39.4f, 132f, 44.6f),
        Segment(160.6f, 65f, 155.4f, 68f),
        Segment(160.6f, 135f, 155.4f, 132f),
        Segment(135f, 160.6f, 132f, 155.4f),
        Segment(65f, 160.6f, 68f, 155.4f),
        Segment(39.4f, 135f, 44.6f, 132f),
        Segment(39.4f, 65f, 44.6f, 68f),
        Segment(65f, 39.4f, 68f, 44.6f),
    )

    const val NeedleEndX = 128f
    const val NeedleEndY = 51.5f
    const val TailEndX = 91f
    const val TailEndY = 115.6f
}

@Composable
fun WelcomeMarkGlyph() {
    val color = BeidTheme.colors.actionPrimary
    Canvas(modifier = Modifier.fillMaxSize(0.68f)) {
        val s = size.minDimension / ViewBoxSize
        fun p(x: Float, y: Float) = Offset(x * s, y * s)
        val center = p(WelcomeMarkGeometry.Center, WelcomeMarkGeometry.Center)

        drawCircle(
            color = color,
            radius = WelcomeMarkGeometry.OuterRingRadius * s,
            center = center,
            style = Stroke(width = WelcomeMarkGeometry.OuterRingStrokeWidth * s),
        )
        drawCircle(
            color = color,
            radius = WelcomeMarkGeometry.InnerRingRadius * s,
            center = center,
            alpha = WelcomeMarkGeometry.InnerRingAlpha,
            style = Stroke(width = WelcomeMarkGeometry.InnerRingStrokeWidth * s),
        )

        WelcomeMarkGeometry.cardinalTicks.forEach { tick ->
            drawLine(
                color = color,
                start = p(tick.x1, tick.y1),
                end = p(tick.x2, tick.y2),
                strokeWidth = WelcomeMarkGeometry.CardinalTickStrokeWidth * s,
            )
        }
        WelcomeMarkGeometry.minorTicks.forEach { tick ->
            drawLine(
                color = color,
                start = p(tick.x1, tick.y1),
                end = p(tick.x2, tick.y2),
                strokeWidth = WelcomeMarkGeometry.MinorTickStrokeWidth * s,
            )
        }

        drawLine(
            color = color,
            start = center,
            end = p(WelcomeMarkGeometry.NeedleEndX, WelcomeMarkGeometry.NeedleEndY),
            strokeWidth = WelcomeMarkGeometry.NeedleStrokeWidth * s,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = color,
            start = center,
            end = p(WelcomeMarkGeometry.TailEndX, WelcomeMarkGeometry.TailEndY),
            strokeWidth = WelcomeMarkGeometry.NeedleStrokeWidth * s,
            cap = StrokeCap.Round,
        )

        drawCircle(color = color, radius = WelcomeMarkGeometry.PivotRadius * s, center = center)
    }
}

/**
 * Ports iOS's `encounter-field-pulse` illustration
 * (`ios/Beid/DesignSystem/Illustrations.xcassets/encounter-field-pulse.imageset/encounter-field-pulse.svg`
 * — concentric sensing rings plus scattered presence dots. Drawn in
 * [BeidTheme.colors.actionPrimary] (ink), not the removed `signalActive`
 * teal `#18C7A7` the iOS SVG still uses, until the radar/screens step
 * replaces it (DECISIONS.md 2026-11-18, Android Flat 2b foundation).
 */
private object EncounterFieldPulseGeometry {
    const val Center = 100f
    const val Ring1Radius = 28f
    const val Ring1StrokeWidth = 2f
    const val Ring1Alpha = 0.9f
    const val Ring2Radius = 52f
    const val Ring2StrokeWidth = 1.8f
    const val Ring2Alpha = 0.55f
    const val Ring3Radius = 78f
    const val Ring3StrokeWidth = 1.5f
    const val Ring3Alpha = 0.3f

    val dot1Center = 128f to 70f
    const val Dot1Radius = 3.5f
    const val Dot1Alpha = 0.9f
    val dot2Center = 55f to 128f
    const val Dot2Radius = 2.5f
    const val Dot2Alpha = 0.65f
    val dot3Center = 156f to 128f
    const val Dot3Radius = 3f
    const val Dot3Alpha = 0.8f

    const val CenterDotRadius = 6f
}

@Composable
fun EncounterFieldPulseGlyph() {
    val color = BeidTheme.colors.actionPrimary
    Canvas(modifier = Modifier.fillMaxSize(0.68f)) {
        val s = size.minDimension / ViewBoxSize
        fun p(x: Float, y: Float) = Offset(x * s, y * s)
        val center = p(EncounterFieldPulseGeometry.Center, EncounterFieldPulseGeometry.Center)

        drawCircle(
            color = color,
            radius = EncounterFieldPulseGeometry.Ring1Radius * s,
            center = center,
            alpha = EncounterFieldPulseGeometry.Ring1Alpha,
            style = Stroke(width = EncounterFieldPulseGeometry.Ring1StrokeWidth * s),
        )
        drawCircle(
            color = color,
            radius = EncounterFieldPulseGeometry.Ring2Radius * s,
            center = center,
            alpha = EncounterFieldPulseGeometry.Ring2Alpha,
            style = Stroke(width = EncounterFieldPulseGeometry.Ring2StrokeWidth * s),
        )
        drawCircle(
            color = color,
            radius = EncounterFieldPulseGeometry.Ring3Radius * s,
            center = center,
            alpha = EncounterFieldPulseGeometry.Ring3Alpha,
            style = Stroke(width = EncounterFieldPulseGeometry.Ring3StrokeWidth * s),
        )

        drawCircle(
            color = color,
            radius = EncounterFieldPulseGeometry.Dot1Radius * s,
            center = p(EncounterFieldPulseGeometry.dot1Center.first, EncounterFieldPulseGeometry.dot1Center.second),
            alpha = EncounterFieldPulseGeometry.Dot1Alpha,
        )
        drawCircle(
            color = color,
            radius = EncounterFieldPulseGeometry.Dot2Radius * s,
            center = p(EncounterFieldPulseGeometry.dot2Center.first, EncounterFieldPulseGeometry.dot2Center.second),
            alpha = EncounterFieldPulseGeometry.Dot2Alpha,
        )
        drawCircle(
            color = color,
            radius = EncounterFieldPulseGeometry.Dot3Radius * s,
            center = p(EncounterFieldPulseGeometry.dot3Center.first, EncounterFieldPulseGeometry.dot3Center.second),
            alpha = EncounterFieldPulseGeometry.Dot3Alpha,
        )

        drawCircle(color = color, radius = EncounterFieldPulseGeometry.CenterDotRadius * s, center = center)
    }
}

/**
 * Ports iOS's `proof-seal-mark` illustration
 * (`ios/Beid/DesignSystem/Illustrations.xcassets/proof-seal-mark.imageset/proof-seal-mark.svg`
 * — a signet-ring rim plus a stamped bar mark. Drawn in
 * [BeidTheme.colors.actionPrimary] (ink), not the removed `proofSeal`
 * violet `#6E5AEF` the iOS SVG still uses, until the radar/screens step
 * replaces it (DECISIONS.md 2026-11-18, Android Flat 2b foundation).
 */
private object ProofSealMarkGeometry {
    const val Center = 100f
    const val OuterRingRadius = 62f
    const val OuterRingStrokeWidth = 7f
    const val InnerRingRadius = 45f
    const val InnerRingStrokeWidth = 3.5f

    const val BarX = 94f
    const val BarStartY = 78f
    const val BarEndY = 122f
    const val BarStrokeWidth = 10f

    val impressionDotCenter = 115f to 116f
    const val ImpressionDotRadius = 8f
}

@Composable
fun ProofSealMarkGlyph() {
    val color = BeidTheme.colors.actionPrimary
    Canvas(modifier = Modifier.fillMaxSize(0.68f)) {
        val s = size.minDimension / ViewBoxSize
        fun p(x: Float, y: Float) = Offset(x * s, y * s)
        val center = p(ProofSealMarkGeometry.Center, ProofSealMarkGeometry.Center)

        drawCircle(
            color = color,
            radius = ProofSealMarkGeometry.OuterRingRadius * s,
            center = center,
            style = Stroke(width = ProofSealMarkGeometry.OuterRingStrokeWidth * s),
        )
        drawCircle(
            color = color,
            radius = ProofSealMarkGeometry.InnerRingRadius * s,
            center = center,
            style = Stroke(width = ProofSealMarkGeometry.InnerRingStrokeWidth * s),
        )

        drawLine(
            color = color,
            start = p(ProofSealMarkGeometry.BarX, ProofSealMarkGeometry.BarStartY),
            end = p(ProofSealMarkGeometry.BarX, ProofSealMarkGeometry.BarEndY),
            strokeWidth = ProofSealMarkGeometry.BarStrokeWidth * s,
            cap = StrokeCap.Round,
        )

        drawCircle(
            color = color,
            radius = ProofSealMarkGeometry.ImpressionDotRadius * s,
            center = p(
                ProofSealMarkGeometry.impressionDotCenter.first,
                ProofSealMarkGeometry.impressionDotCenter.second,
            ),
        )
    }
}

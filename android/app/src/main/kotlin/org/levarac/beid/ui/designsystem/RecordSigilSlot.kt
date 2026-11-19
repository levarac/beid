package org.levarac.beid.ui.designsystem

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.hideFromAccessibility
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import org.levarac.beid.shared.sigil.SigilGround
import org.levarac.beid.shared.sigil.SigilInput
import org.levarac.beid.ui.theme.BeidColorScheme
import org.levarac.beid.ui.theme.BeidSize
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/**
 * Every place a record's Sigil is drawn, with its size and both grounds: port
 * of iOS `RecordSigilPlacement` (`ios/Beid/DesignSystem/RecordSigilSlot.swift`)
 * with the drafts' [RecordsGrid] (feat/ios-v2-now-records,
 * integration/ios-1.1.1).
 *
 * The grounds were measured from the Flat 2b Figma exports (beid#653 OD-6):
 * 07 and 09 (and the Records grid) draw the Sigil on a filled ink disc; 04,
 * 04c, 06, 08 and 12 draw it with no ground, and 04's active card and 06 sit
 * on an ink page. The full/mini variant is not decided here: `layoutSigil`
 * picks it from the size, so the 60, 48 and 40 rows are minis.
 */
enum class RecordSigilPlacement {
    /** Frame 04, the in-progress card (node 183:13). */
    HomeActiveCard,

    /** Frames 04 / 04c, a past event row (nodes 183:54, 203:47). */
    HomePastRow,

    /** The saved-record grid (Attendance tiles): an ink disc on the canvas. */
    RecordsGrid,

    /** Frame 06, Sensing — Sealed (node 184:65). */
    SensingSealed,

    /** Frame 07, Proof Collected (node 183:222). */
    ProofCollected,

    /** Frame 08, an Event Detail session row (node 184:266). */
    EventDetailRow,

    /** Frame 09, Proof Detail (node 204:36). */
    ProofDetail,

    /** Frame 12, a Report Detail session-proof row (nodes 206:174, 206:213). */
    ReportDetailRow,
    ;

    val size: Dp
        get() = when (this) {
            HomeActiveCard -> 84.dp
            HomePastRow -> 60.dp
            RecordsGrid -> BeidSize.recordsGridSigil
            SensingSealed -> BeidSize.sensingSealedSigil
            ProofCollected -> 290.dp
            EventDetailRow -> BeidSize.proofRowMinHeight - BeidSpacing.l
            ProofDetail -> BeidSize.proofDetailSigil
            ReportDetailRow -> 40.dp
        }

    val page: RecordSigilSlot.Ground
        get() = when (this) {
            HomeActiveCard, SensingSealed -> RecordSigilSlot.Ground.Ink
            HomePastRow, RecordsGrid, ProofCollected, EventDetailRow, ProofDetail, ReportDetailRow ->
                RecordSigilSlot.Ground.Canvas
        }

    val sigilGround: SigilGround
        get() = when (this) {
            ProofCollected, ProofDetail, RecordsGrid -> SigilGround.DISC
            HomeActiveCard, HomePastRow, SensingSealed, EventDetailRow, ReportDetailRow -> SigilGround.NONE
        }
}

/**
 * A record's Sigil (beid#653), or the neutral ring when the record has no
 * Sigil data. `null` is the only "no data" signal; nothing is inferred from
 * counts. The ring is hidden from accessibility; a drawn Sigil carries its
 * summary through [BeidSigil].
 */
object RecordSigilSlot {
    /** The page the slot sits on. */
    enum class Ground {
        Canvas,
        Ink,
        ;

        val sigilPage: SigilPage
            get() = when (this) {
                Canvas -> SigilPage.Canvas
                Ink -> SigilPage.Ink
            }

        internal fun ringColor(colors: BeidColorScheme) = when (this) {
            Canvas -> colors.strokeHairline
            Ink -> colors.strokeHairlineOnInk
        }
    }

    /** What the slot draws for a given input. Pure, so "no data → ring" can be pinned by a test. */
    sealed interface Artwork {
        data object NeutralRing : Artwork

        data class Sigil(val input: SigilInput) : Artwork
    }

    fun artwork(input: SigilInput?): Artwork = if (input == null) Artwork.NeutralRing else Artwork.Sigil(input)

    @Composable
    operator fun invoke(
        input: SigilInput?,
        placement: RecordSigilPlacement,
        modifier: Modifier = Modifier,
        isDeviceRecord: Boolean = false,
    ) {
        when (val artwork = artwork(input)) {
            Artwork.NeutralRing -> NeutralRing(placement, modifier)
            is Artwork.Sigil -> BeidSigil(
                input = artwork.input,
                size = placement.size,
                ground = placement.sigilGround,
                modifier = modifier,
                page = placement.page.sigilPage,
                isDeviceRecord = isDeviceRecord,
            )
        }
    }

    /** iOS `Circle().strokeBorder(_, lineWidth: hairline)`: the stroke stays inside the frame. */
    @Composable
    private fun NeutralRing(placement: RecordSigilPlacement, modifier: Modifier) {
        val color = placement.page.ringColor(BeidTheme.colors)
        Canvas(
            modifier
                .size(placement.size)
                .clearAndSetSemantics { hideFromAccessibility() },
        ) {
            val width = BeidSize.hairline.toPx()
            drawCircle(color = color, radius = (size.minDimension - width) / 2, style = Stroke(width = width))
        }
    }
}

package org.levarac.beid.ui.designsystem

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.levarac.beid.shared.sigil.SigilGround
import org.levarac.beid.shared.sigil.SigilPrimitiveKind
import org.levarac.beid.shared.sigil.addSigilPresence
import org.levarac.beid.shared.sigil.createSigilInput
import org.levarac.beid.shared.sigil.layoutSigil

/**
 * Port of iOS `RecordSigilPresentationTests` (draft feat/ios-v2-now-records /
 * integration/ios-1.1.1, which add `.recordsGrid`). The coordinator half of
 * the iOS file is not ported: Android has no stored Sigil presence yet.
 *
 * Sizes, pages and grounds are literal expectations, as on iOS, so a token
 * regression is caught rather than moving both sides of the comparison.
 */
class RecordSigilPresentationTest {

    private data class Expected(val size: Dp, val page: RecordSigilSlot.Ground, val sigilGround: SigilGround)

    @Test
    fun everyPlacementHasItsMeasuredSizeAndGrounds() {
        val expected = mapOf(
            RecordSigilPlacement.HomeActiveCard to Expected(84.dp, RecordSigilSlot.Ground.Ink, SigilGround.NONE),
            RecordSigilPlacement.HomePastRow to Expected(60.dp, RecordSigilSlot.Ground.Canvas, SigilGround.NONE),
            RecordSigilPlacement.RecordsGrid to Expected(104.dp, RecordSigilSlot.Ground.Canvas, SigilGround.DISC),
            RecordSigilPlacement.SensingSealed to Expected(300.dp, RecordSigilSlot.Ground.Ink, SigilGround.NONE),
            RecordSigilPlacement.ProofCollected to Expected(290.dp, RecordSigilSlot.Ground.Canvas, SigilGround.DISC),
            RecordSigilPlacement.EventDetailRow to Expected(48.dp, RecordSigilSlot.Ground.Canvas, SigilGround.NONE),
            RecordSigilPlacement.ProofDetail to Expected(200.dp, RecordSigilSlot.Ground.Canvas, SigilGround.DISC),
            RecordSigilPlacement.ReportDetailRow to Expected(40.dp, RecordSigilSlot.Ground.Canvas, SigilGround.NONE),
        )
        assertEquals(8, RecordSigilPlacement.entries.size)
        assertEquals(RecordSigilPlacement.entries.toSet(), expected.keys)
        for (placement in RecordSigilPlacement.entries) {
            val want = expected.getValue(placement)
            assertEquals("$placement size", want.size, placement.size)
            assertEquals("$placement page", want.page, placement.page)
            assertEquals("$placement ground", want.sigilGround, placement.sigilGround)
        }
    }

    @Test
    fun theRowPlacementsAreMinisAndTheRestAreFull() {
        val input = createSigilInput(1)
        val minis = setOf(
            RecordSigilPlacement.HomePastRow,
            RecordSigilPlacement.EventDetailRow,
            RecordSigilPlacement.ReportDetailRow,
        )
        for (placement in RecordSigilPlacement.entries) {
            val layout = layoutSigil(input, placement.size.value.toDouble(), placement.sigilGround)
            assertTrue("$placement", layout.isSuccess)
            assertEquals("$placement", placement in minis, layout.isMini)
        }
    }

    @Test
    fun noInputDrawsTheNeutralRingAndAnInputDrawsTheSigil() {
        assertSame(RecordSigilSlot.Artwork.NeutralRing, RecordSigilSlot.artwork(null))
        val input = createSigilInput(1)
        val artwork = RecordSigilSlot.artwork(input)
        assertTrue("a record with data must draw its Sigil", artwork is RecordSigilSlot.Artwork.Sigil)
        assertSame(input, (artwork as RecordSigilSlot.Artwork.Sigil).input)
    }

    @Test
    fun marksOnAnInkPageAreBgAndTheGroundStaysInk() {
        val marks = listOf(
            SigilPrimitiveKind.RING,
            SigilPrimitiveKind.DETECTED_LINE,
            SigilPrimitiveKind.MUTUAL_LINE,
            SigilPrimitiveKind.DETECTED_DOT,
            SigilPrimitiveKind.MUTUAL_DOT,
            SigilPrimitiveKind.CENTER_DOT,
        )
        for (kind in marks) {
            assertEquals(SigilInkRole.OnInk, SigilDrawing.inkRole(kind, SigilGround.NONE, SigilPage.Ink))
            assertEquals(SigilInkRole.Ink, SigilDrawing.inkRole(kind, SigilGround.NONE, SigilPage.Canvas))
            assertEquals(SigilInkRole.OnInk, SigilDrawing.inkRole(kind, SigilGround.DISC, SigilPage.Canvas))
            assertEquals("default page is canvas", SigilInkRole.Ink, SigilDrawing.inkRole(kind, SigilGround.NONE))
        }
        assertEquals(SigilInkRole.Ink, SigilDrawing.inkRole(SigilPrimitiveKind.GROUND_DISC, SigilGround.DISC, SigilPage.Ink))
        assertEquals(SigilInkRole.Ink, SigilDrawing.inkRole(SigilPrimitiveKind.GROUND_OUTLINE, SigilGround.OUTLINE, SigilPage.Ink))
        assertEquals(SigilPage.Ink, RecordSigilSlot.Ground.Ink.sigilPage)
        assertEquals(SigilPage.Canvas, RecordSigilSlot.Ground.Canvas.sigilPage)
    }

    @Test
    fun everyMarkOnTheInkPagePlacementsIsDrawnInBg() {
        val input = createSigilInput(3)
        for ((peer, window) in listOf("a" to 0, "a" to 1, "b" to 2)) {
            assertTrue(addSigilPresence(input, peer, window, 1))
        }
        val inkPlacements = RecordSigilPlacement.entries.filter { it.page == RecordSigilSlot.Ground.Ink }
        assertEquals(setOf(RecordSigilPlacement.HomeActiveCard, RecordSigilPlacement.SensingSealed), inkPlacements.toSet())
        for (placement in inkPlacements) {
            val layout = layoutSigil(input, placement.size.value.toDouble(), placement.sigilGround)
            val commands = SigilDrawing.commands(layout, placement.sigilGround, placement.page.sigilPage)
            assertFalse("$placement", commands.isEmpty())
            commands.forEach { assertEquals("$placement: an ink mark on an ink page is invisible", SigilInkRole.OnInk, it.role) }
        }
    }
}

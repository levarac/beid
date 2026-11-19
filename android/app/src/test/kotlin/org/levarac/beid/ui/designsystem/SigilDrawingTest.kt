package org.levarac.beid.ui.designsystem

import android.content.res.Resources
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.shared.sigil.SigilGround
import org.levarac.beid.shared.sigil.SigilInput
import org.levarac.beid.shared.sigil.SigilLayout
import org.levarac.beid.shared.sigil.SigilPrimitiveKind
import org.levarac.beid.shared.sigil.addSigilPresence
import org.levarac.beid.shared.sigil.createSigilInput
import org.levarac.beid.shared.sigil.layoutSigil
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Port of iOS `SigilViewTests` (origin/integration/ios-1.1.1): pins the
 * transport from shared's `layoutSigil` output to [SigilDrawCommand]s.
 *
 * Every coordinate, radius and width asserted below is read back out of the
 * layout, never written here, and compared exactly (delta 0.0): a transport
 * performs no arithmetic, so there is no rounding to tolerate. That is the
 * evidence that the Android layer makes no geometry decision.
 *
 * Robolectric only because the accessibility summaries are string resources.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SigilDrawingTest {
    private val resources: Resources get() = ApplicationProvider.getApplicationContext<android.content.Context>().resources

    // region Fixtures

    private data class Entry(val key: String, val window: Int, val presence: Int)

    private fun input(windowCount: Int, entries: List<Entry>): SigilInput {
        val input = createSigilInput(windowCount)
        entries.forEach { assertTrue("rejected $it", addSigilPresence(input, it.key, it.window, it.presence)) }
        return input
    }

    /** Three peers, four windows, both presences: the full variant emits all six mark kinds. */
    private val mixedEntries = listOf(
        Entry("peer-a", 0, 2),
        Entry("peer-a", 1, 2),
        Entry("peer-a", 2, 1),
        Entry("peer-b", 1, 1),
        Entry("peer-b", 2, 1),
        Entry("peer-b", 3, 2),
        Entry("peer-c", 0, 1),
        Entry("peer-c", 3, 2),
    )

    private val allGrounds = listOf(SigilGround.DISC, SigilGround.OUTLINE, SigilGround.NONE)
    private val fullSize = 200.0
    private val miniSize = 60.0

    private fun count(kind: SigilPrimitiveKind, layout: SigilLayout): Int =
        (0 until layout.primitiveCount).count { layout.primitiveAt(it)!!.kind == kind }

    private fun commandsFor(entries: List<Entry>, windowCount: Int, size: Double, ground: SigilGround) =
        layoutSigil(input(windowCount, entries), size, ground).let { it to SigilDrawing.commands(it, ground) }

    // endregion

    // region The core assertion

    private fun assertCommandsMatchLayout(
        commands: List<SigilDrawCommand>,
        layout: SigilLayout,
        ground: SigilGround,
        page: SigilPage = SigilPage.Canvas,
    ) {
        assertTrue("layout failed: ${layout.errorCode}", layout.isSuccess)
        assertEquals("exactly one command per primitive", layout.primitiveCount, commands.size)
        commands.forEachIndexed { index, command ->
            val primitive = layout.primitiveAt(index) ?: return fail("no primitive at $index")
            val role = SigilDrawing.inkRole(primitive.kind, ground, page)
            assertEquals("[$index] role", role, command.role)
            when (command) {
                is SigilDrawCommand.Fill -> {
                    assertEquals("[$index] shape", SigilMarkShape.FilledCircle, SigilDrawing.markShape(primitive.kind))
                    assertEquals("[$index] x", primitive.x, command.centerX, 0.0)
                    assertEquals("[$index] y", primitive.y, command.centerY, 0.0)
                    assertEquals("[$index] radius", primitive.radius, command.radius, 0.0)
                }
                is SigilDrawCommand.StrokeCircle -> {
                    assertEquals("[$index] shape", SigilMarkShape.StrokedCircle, SigilDrawing.markShape(primitive.kind))
                    assertEquals("[$index] x", primitive.x, command.centerX, 0.0)
                    assertEquals("[$index] y", primitive.y, command.centerY, 0.0)
                    assertEquals("[$index] radius", primitive.radius, command.radius, 0.0)
                    assertEquals("[$index] lineWidth", primitive.lineWidth, command.lineWidth, 0.0)
                }
                is SigilDrawCommand.StrokeLine -> {
                    assertEquals("[$index] shape", SigilMarkShape.Segment, SigilDrawing.markShape(primitive.kind))
                    assertEquals("[$index] from.x", primitive.x, command.fromX, 0.0)
                    assertEquals("[$index] from.y", primitive.y, command.fromY, 0.0)
                    assertEquals("[$index] to.x", primitive.x2, command.toX, 0.0)
                    assertEquals("[$index] to.y", primitive.y2, command.toY, 0.0)
                    assertEquals("[$index] lineWidth", primitive.lineWidth, command.lineWidth, 0.0)
                }
            }
        }
    }

    // endregion

    @Test
    fun identicalInputsBuiltInDifferentOrdersProduceIdenticalCommands() {
        for (ground in allGrounds) {
            for (size in listOf(fullSize, miniSize)) {
                val first = SigilDrawing.commands(layoutSigil(input(4, mixedEntries), size, ground), ground)
                val second = SigilDrawing.commands(layoutSigil(input(4, mixedEntries.reversed()), size, ground), ground)
                assertFalse("size $size", first.isEmpty())
                assertEquals("size $size", first, second)
            }
        }
    }

    @Test
    fun everyCommandCarriesTheLayoutsOwnNumbersInOrder() {
        for (ground in allGrounds) {
            for (size in listOf(fullSize, miniSize)) {
                for (page in SigilPage.entries) {
                    val layout = layoutSigil(input(4, mixedEntries), size, ground)
                    assertCommandsMatchLayout(SigilDrawing.commands(layout, ground, page), layout, ground, page)
                }
            }
        }
    }

    /**
     * Literal cross-check against shared's own golden numbers at size 200: the
     * DISC ground is a filled circle at (100, 100) radius 100, and the full
     * variant's centre dot is 11k = 11 at the centre (SigilLayout.kt).
     */
    @Test
    fun groundAndCentreCommandsCarrySharedLiterals() {
        val (_, commands) = commandsFor(mixedEntries, 4, fullSize, SigilGround.DISC)
        assertEquals(SigilDrawCommand.Fill(100.0, 100.0, 100.0, SigilInkRole.Ink), commands.first())
        assertEquals(SigilDrawCommand.Fill(100.0, 100.0, 11.0, SigilInkRole.OnInk), commands.last())

        val (_, outline) = commandsFor(mixedEntries, 4, fullSize, SigilGround.OUTLINE)
        assertEquals(SigilDrawCommand.StrokeCircle(100.0, 100.0, 99.4, 1.2, SigilInkRole.Ink), outline.first())
    }

    @Test
    fun commandOrderIsThePrimitiveOrderOneForOne() {
        val (layout, commands) = commandsFor(mixedEntries, 4, fullSize, SigilGround.DISC)
        val expected = (0 until layout.primitiveCount).map { SigilDrawing.markShape(layout.primitiveAt(it)!!.kind) }
        val actual = commands.map {
            when (it) {
                is SigilDrawCommand.Fill -> SigilMarkShape.FilledCircle
                is SigilDrawCommand.StrokeCircle -> SigilMarkShape.StrokedCircle
                is SigilDrawCommand.StrokeLine -> SigilMarkShape.Segment
            }
        }
        assertEquals(expected, actual)
    }

    @Test
    fun everyPrimitiveKindMapsToAShape() {
        val expected = mapOf(
            SigilPrimitiveKind.GROUND_DISC to SigilMarkShape.FilledCircle,
            SigilPrimitiveKind.GROUND_OUTLINE to SigilMarkShape.StrokedCircle,
            SigilPrimitiveKind.RING to SigilMarkShape.StrokedCircle,
            SigilPrimitiveKind.DETECTED_LINE to SigilMarkShape.Segment,
            SigilPrimitiveKind.MUTUAL_LINE to SigilMarkShape.Segment,
            SigilPrimitiveKind.DETECTED_DOT to SigilMarkShape.FilledCircle,
            SigilPrimitiveKind.MUTUAL_DOT to SigilMarkShape.FilledCircle,
            SigilPrimitiveKind.CENTER_DOT to SigilMarkShape.FilledCircle,
        )
        assertEquals(SigilPrimitiveKind.entries.toSet(), expected.keys)
        expected.forEach { (kind, shape) -> assertEquals(kind.name, shape, SigilDrawing.markShape(kind)) }
    }

    @Test
    fun everyPrimitiveKindMapsToAnInkRoleOnEveryGround() {
        for (ground in allGrounds) {
            assertEquals(SigilInkRole.Ink, SigilDrawing.inkRole(SigilPrimitiveKind.GROUND_DISC, ground))
            assertEquals(SigilInkRole.Ink, SigilDrawing.inkRole(SigilPrimitiveKind.GROUND_OUTLINE, ground))
        }
        val marks = SigilPrimitiveKind.entries - setOf(SigilPrimitiveKind.GROUND_DISC, SigilPrimitiveKind.GROUND_OUTLINE)
        assertEquals(6, marks.size)
        for (kind in marks) {
            assertEquals(SigilInkRole.OnInk, SigilDrawing.inkRole(kind, SigilGround.DISC))
            assertEquals(SigilInkRole.Ink, SigilDrawing.inkRole(kind, SigilGround.OUTLINE))
            assertEquals(SigilInkRole.Ink, SigilDrawing.inkRole(kind, SigilGround.NONE))
        }
    }

    @Test
    fun discGroundLeadsWithAFilledInkDiscAndPaintsItsMarksInBg() {
        val (layout, commands) = commandsFor(mixedEntries, 4, fullSize, SigilGround.DISC)
        assertEquals(1, count(SigilPrimitiveKind.GROUND_DISC, layout))
        val first = layout.primitiveAt(0)!!
        assertEquals(SigilDrawCommand.Fill(first.x, first.y, first.radius, SigilInkRole.Ink), commands.first())
        commands.drop(1).forEach { assertEquals(SigilInkRole.OnInk, it.role) }
    }

    @Test
    fun outlineGroundLeadsWithAStrokedInkCircle() {
        val (layout, commands) = commandsFor(mixedEntries, 4, fullSize, SigilGround.OUTLINE)
        assertEquals(1, count(SigilPrimitiveKind.GROUND_OUTLINE, layout))
        val first = layout.primitiveAt(0)!!
        assertEquals(
            SigilDrawCommand.StrokeCircle(first.x, first.y, first.radius, first.lineWidth, SigilInkRole.Ink),
            commands.first(),
        )
        commands.drop(1).forEach { assertEquals(SigilInkRole.Ink, it.role) }
    }

    @Test
    fun noGroundEmitsNeitherGroundPrimitiveAndIsExactlyOneCommandShorter() {
        val (none, noneCommands) = commandsFor(mixedEntries, 4, fullSize, SigilGround.NONE)
        assertEquals(0, count(SigilPrimitiveKind.GROUND_DISC, none))
        assertEquals(0, count(SigilPrimitiveKind.GROUND_OUTLINE, none))
        assertEquals(commandsFor(mixedEntries, 4, fullSize, SigilGround.DISC).second.size - 1, noneCommands.size)
        assertEquals(commandsFor(mixedEntries, 4, fullSize, SigilGround.OUTLINE).second.size - 1, noneCommands.size)
    }

    @Test
    fun miniSizeDropsTheFullVariantOnlyKindsAndFullSizeDrawsRings() {
        val ground = SigilGround.NONE
        val (mini, miniCommands) = commandsFor(mixedEntries, 4, miniSize, ground)
        assertTrue(mini.isMini)
        assertEquals(0, count(SigilPrimitiveKind.RING, mini))
        assertEquals(0, count(SigilPrimitiveKind.DETECTED_LINE, mini))
        assertEquals(0, count(SigilPrimitiveKind.DETECTED_DOT, mini))
        assertEquals(0, miniCommands.filterIsInstance<SigilDrawCommand.StrokeCircle>().size)
        assertCommandsMatchLayout(miniCommands, mini, ground)

        val (full, fullCommands) = commandsFor(mixedEntries, 4, fullSize, ground)
        assertFalse(full.isMini)
        assertEquals(full.ringCount, count(SigilPrimitiveKind.RING, full))
        assertEquals(full.ringCount, fullCommands.filterIsInstance<SigilDrawCommand.StrokeCircle>().size)
        assertCommandsMatchLayout(fullCommands, full, ground)
    }

    @Test
    fun anIsolatedPresenceTwoDrawsADotAndNoLine() {
        for (size in listOf(miniSize, fullSize)) {
            val (layout, commands) = commandsFor(listOf(Entry("peer-a", 0, 2)), 2, size, SigilGround.NONE)
            assertEquals("size $size", 1, count(SigilPrimitiveKind.MUTUAL_DOT, layout))
            assertEquals("size $size", 0, count(SigilPrimitiveKind.MUTUAL_LINE, layout))
            assertEquals("size $size", 0, count(SigilPrimitiveKind.DETECTED_LINE, layout))
            assertEquals("size $size", 0, commands.filterIsInstance<SigilDrawCommand.StrokeLine>().size)
            assertEquals("size $size", 2, commands.filterIsInstance<SigilDrawCommand.Fill>().size)
            assertCommandsMatchLayout(commands, layout, SigilGround.NONE)
        }
    }

    @Test
    fun twoConsecutivePresenceTwoRingsDrawAMutualLine() {
        val entries = listOf(Entry("peer-a", 0, 2), Entry("peer-a", 1, 2))
        val (mini, miniCommands) = commandsFor(entries, 2, miniSize, SigilGround.NONE)
        assertTrue(mini.isMini)
        assertEquals(1, count(SigilPrimitiveKind.MUTUAL_LINE, mini))
        assertEquals(0, count(SigilPrimitiveKind.MUTUAL_DOT, mini))
        assertEquals(1, miniCommands.filterIsInstance<SigilDrawCommand.StrokeLine>().size)
        assertCommandsMatchLayout(miniCommands, mini, SigilGround.NONE)

        val (full, fullCommands) = commandsFor(entries, 2, fullSize, SigilGround.NONE)
        assertEquals(1, count(SigilPrimitiveKind.MUTUAL_LINE, full))
        assertEquals(0, count(SigilPrimitiveKind.DETECTED_LINE, full))
        assertEquals(1, fullCommands.filterIsInstance<SigilDrawCommand.StrokeLine>().size)
        assertCommandsMatchLayout(fullCommands, full, SigilGround.NONE)
    }

    @Test
    fun aMixedPresencePairDrawsADetectedLineThinnerThanTheMutualOne() {
        val (mixed, mixedCommands) = commandsFor(listOf(Entry("peer-a", 0, 2), Entry("peer-a", 1, 1)), 2, fullSize, SigilGround.NONE)
        assertEquals(1, count(SigilPrimitiveKind.DETECTED_LINE, mixed))
        assertEquals(0, count(SigilPrimitiveKind.MUTUAL_LINE, mixed))
        assertEquals(1, count(SigilPrimitiveKind.MUTUAL_DOT, mixed))
        assertEquals(1, count(SigilPrimitiveKind.DETECTED_DOT, mixed))
        assertCommandsMatchLayout(mixedCommands, mixed, SigilGround.NONE)

        val (_, mutualCommands) = commandsFor(listOf(Entry("peer-a", 0, 2), Entry("peer-a", 1, 2)), 2, fullSize, SigilGround.NONE)
        val detectedLine = mixedCommands.filterIsInstance<SigilDrawCommand.StrokeLine>().single()
        val mutualLine = mutualCommands.filterIsInstance<SigilDrawCommand.StrokeLine>().single()
        assertTrue(mutualLine.lineWidth > detectedLine.lineWidth)
    }

    @Test
    fun aSizeBelowTheSharedMinimumProducesNoCommands() {
        for (ground in allGrounds) {
            val layout = layoutSigil(input(4, mixedEntries), 1.0, ground)
            assertFalse(layout.isSuccess)
            assertNotNull(layout.errorCode)
            assertEquals(emptyList<SigilDrawCommand>(), SigilDrawing.commands(layout, ground))
        }
    }

    @Test
    fun emptyInputStillDrawsACentreDotAndItsGround() {
        val disc = layoutSigil(createSigilInput(4), fullSize, SigilGround.DISC)
        assertEquals(0, disc.peerCount)
        assertEquals(1, count(SigilPrimitiveKind.GROUND_DISC, disc))
        assertEquals(1, count(SigilPrimitiveKind.CENTER_DOT, disc))
        assertCommandsMatchLayout(SigilDrawing.commands(disc, SigilGround.DISC), disc, SigilGround.DISC)

        val outline = layoutSigil(createSigilInput(4), fullSize, SigilGround.OUTLINE)
        assertEquals(1, count(SigilPrimitiveKind.GROUND_OUTLINE, outline))
        assertEquals(1, count(SigilPrimitiveKind.CENTER_DOT, outline))
        assertCommandsMatchLayout(SigilDrawing.commands(outline, SigilGround.OUTLINE), outline, SigilGround.OUTLINE)

        val mini = layoutSigil(createSigilInput(4), miniSize, SigilGround.NONE)
        val miniCommands = SigilDrawing.commands(mini, SigilGround.NONE)
        assertTrue(mini.isMini)
        assertEquals(1, miniCommands.size)
        assertEquals(1, miniCommands.filterIsInstance<SigilDrawCommand.Fill>().size)
        assertCommandsMatchLayout(miniCommands, mini, SigilGround.NONE)
    }

    // region Accessibility

    @Test
    fun mutualAndDetectedPeerCountsPartitionThePeerCount() {
        for (ground in allGrounds) {
            for (size in listOf(fullSize, miniSize)) {
                val layout = layoutSigil(input(4, mixedEntries), size, ground)
                assertEquals(layout.peerCount, layout.mutualPeerCount + layout.detectedPeerCount)
            }
        }
    }

    @Test
    fun accessibilitySummaryReportsMutualDetectedAndWindowCounts() {
        val layout = layoutSigil(
            input(
                7,
                listOf(
                    Entry("mutual-1", 0, 2),
                    Entry("mutual-2", 1, 2),
                    Entry("detected-1", 2, 1),
                    Entry("detected-2", 3, 1),
                    Entry("detected-3", 4, 1),
                ),
            ),
            fullSize,
            SigilGround.DISC,
        )
        assertEquals(2, layout.mutualPeerCount)
        assertEquals(3, layout.detectedPeerCount)
        assertEquals(7, layout.windowCount)
        assertEquals("2 mutual, 3 detected, window 7", SigilDrawing.accessibilitySummary(layout, resources))
    }

    /** iOS draft integration/ios-1.1.1 `sigil.record.accessibilitySummary`. */
    @Test
    fun deviceRecordSummaryDoesNotTreatMutualityAsAMeasuredCount() {
        for (includesSyntheticMutual in listOf(false, true)) {
            val entries = buildList {
                add(Entry("detected", 0, 1))
                if (includesSyntheticMutual) add(Entry("mutual", 2, 2))
            }
            val layout = layoutSigil(input(3, entries), fullSize, SigilGround.DISC)
            assertEquals(
                "Devices heard: 1. Window 3. Mutual check not available yet.",
                SigilDrawing.recordAccessibilitySummary(layout, resources),
            )
            assertEquals(
                if (includesSyntheticMutual) "1 mutual, 1 detected, window 3" else "0 mutual, 1 detected, window 3",
                SigilDrawing.accessibilitySummary(layout, resources),
            )
        }
    }

    @Test
    fun aFailedLayoutIsHiddenFromAccessibilityAndStillSummarizesAsAllZeros() {
        val failed = layoutSigil(input(4, mixedEntries), 1.0, SigilGround.DISC)
        assertFalse(failed.isSuccess)
        assertTrue(SigilDrawing.isAccessibilityHidden(failed))
        assertEquals("0 mutual, 0 detected, window 0", SigilDrawing.accessibilitySummary(failed, resources))

        val succeeded = layoutSigil(input(4, mixedEntries), fullSize, SigilGround.DISC)
        assertTrue(succeeded.isSuccess)
        assertFalse(SigilDrawing.isAccessibilityHidden(succeeded))
    }

    // endregion
}

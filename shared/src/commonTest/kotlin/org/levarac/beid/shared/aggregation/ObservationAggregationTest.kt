package org.levarac.beid.shared.aggregation

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Vectors for the shared aggregation family.
 *
 * Each test names the defect it exists to catch.
 *
 * Evidence basis, and the limit of the method that produced it.
 *
 * The behaviors below are licensed: each was negated in the production source,
 * one at a time, and at least one vector in this file went red. That is what
 * "licensed" means here, and it is all it means.
 *
 *  - every counting rule at all three tiers, and both scopes of every
 *    dual-scope field;
 *  - the grouping, ordering and absence rules of both series;
 *  - the invalid-width failure path, including what a failed result reports;
 *  - the accumulator's boundary checks, including the size bound's unit
 *    (bytes, not characters), its inclusive edge, and its value; and the two
 *    counting helpers;
 *  - the whole accessor surface — every count property, and the out-of-range
 *    result of all four indexed accessors;
 *  - aggregating being a read: no entry point drains its accumulator, and a
 *    returned result is a snapshot rather than a view.
 *
 * COMPLETENESS IS NOT CLAIMED — and not as a gap to be closed later. A static
 * list cannot support a completeness claim at all, because the list is written
 * by the same understanding that wrote the code: the two share their blind
 * spots, so a behavior neither one thought of is missing from both, and the
 * list looks finished either way. Successive review rounds each falsified a
 * completeness claim made in this comment, and each did it by RE-DERIVING
 * mutations from the source rather than by reading the list — which is the
 * same fact stated twice.
 *
 * So to check this suite, do not audit the list. Re-derive against the source.
 * The holes found that way, as a guide to the shapes worth hunting rather than
 * as a bound on them: a whole absent category (the accessor surface); a
 * cross-call property no single-expression mutation can express (aggregating
 * is a read); an entry correctly named but proving less than its name spanned
 * (the size bound, proved only for ASCII and only above the edge); and a
 * constant a vector cited by reference, which moves both sides of its own
 * comparison. There is no reason to think those are the last shapes.
 *
 * Two further limits on reading any of this. It is about behaviors, not
 * assertion lines — an individual assertion may be redundant with another. And
 * it is a snapshot: an assertion added later carries no licensing of its own,
 * and neither does a field or function added to the production types.
 *
 * Outside this evidence entirely: that the two platforms agree at runtime (the
 * iOS-target tests compile here but are not executed), the generated Swift
 * shape (proved by running the export, not by this suite), and any concurrent
 * use of one accumulator from several threads.
 */
class ObservationAggregationTest {

    /**
     * Catches the live defect tracked in beid#154: counting the per-window peer
     * identifier across windows, which yields (device x window) and inflates
     * with dwell time.
     */
    @Test
    fun sameDeviceAcrossSeveralWindowsCountsAsOneDevice() {
        val input = createAggregationObservationInput()
        assertTrue(addAggregationObservation(input, 100L, "rpi-a1", "device-a", true))
        assertTrue(addAggregationObservation(input, 101L, "rpi-a2", "device-a", true))
        assertTrue(addAggregationObservation(input, 102L, "rpi-a3", "device-a", true))

        val session = aggregateObservationsForSession(input, windowsPerBand = 4)

        assertEquals(1, session.deviceCount)
        assertEquals(1, session.mutualDeviceCount)
        assertEquals(3, session.observationCount)
        assertEquals(0, session.observationsWithoutDisplayIdCount)
        assertEquals(3, session.windowCount)
    }

    /**
     * Catches the mirror-image defect: using the stable display id inside a
     * single window. The per-window identifier does not rotate within a window,
     * so it is the correct thing to count there, and peers that never yielded a
     * display id must still be counted.
     */
    @Test
    fun withinOneWindowThePeerCountUsesThePerWindowKeyNotTheDisplayId() {
        val input = createAggregationObservationInput()
        assertTrue(addAggregationObservation(input, 200L, "rpi-x", "device-x", true))
        assertTrue(addAggregationObservation(input, 200L, "rpi-y", null, true))
        assertTrue(addAggregationObservation(input, 200L, "rpi-z", null, true))

        val windows = aggregateObservationsByWindow(input)

        assertEquals(1, windows.windowCount)
        val window = assertNotNull(windows.windowAt(0))
        assertEquals(200L, window.windowIndex)
        assertEquals(3, window.peerCount)
        assertEquals(3, window.mutualPeerCount)
        assertEquals(3, window.observationCount)
    }

    /**
     * Catches silently folding display-id-less observations into the device
     * count. Their number is reported separately so a caller can judge how much
     * of the session the device count actually covers.
     */
    @Test
    fun observationsWithoutADisplayIdAreExcludedFromTheDeviceCountAndReportedSeparately() {
        val input = createAggregationObservationInput()
        assertTrue(addAggregationObservation(input, 300L, "rpi-a1", "device-a", true))
        assertTrue(addAggregationObservation(input, 301L, "rpi-a2", "device-a", true))
        assertTrue(addAggregationObservation(input, 300L, "rpi-b1", null, true))
        assertTrue(addAggregationObservation(input, 301L, "rpi-b2", null, true))

        val session = aggregateObservationsForSession(input, windowsPerBand = 4)

        assertEquals(1, session.deviceCount)
        assertEquals(2, session.observationsWithoutDisplayIdCount)
        assertEquals(4, session.observationCount)
    }

    /**
     * Catches a dense zero-filled series. A window with no data means "nothing
     * was recorded", which is not the same claim as "recorded, and it was zero".
     */
    @Test
    fun aGapBetweenWindowsSurvivesAsAGapNotAZeroRow() {
        val input = createAggregationObservationInput()
        assertTrue(addAggregationObservation(input, 400L, "rpi-a", "device-a", true))
        assertTrue(addAggregationObservation(input, 403L, "rpi-b", "device-a", true))

        val windows = aggregateObservationsByWindow(input)

        assertEquals(2, windows.windowCount)
        assertEquals(400L, assertNotNull(windows.windowAt(0)).windowIndex)
        assertEquals(403L, assertNotNull(windows.windowAt(1)).windowIndex)

        val bands = aggregateObservationsByBand(input, windowsPerBand = 1)
        assertTrue(bands.isSuccess)
        assertEquals(2, bands.bandCount)
        assertEquals(400L, assertNotNull(bands.bandAt(0)).bandIndex)
        assertEquals(403L, assertNotNull(bands.bandAt(1)).bandIndex)
    }

    /**
     * Catches a band that ignores its declared width. Band width is expressed
     * in windows, never in time, because the ENIN window length is a runtime
     * parameter rather than a constant.
     */
    @Test
    fun bandGroupingAtANonTrivialWidthGroupsWholeWindows() {
        val input = createAggregationObservationInput()
        assertTrue(addAggregationObservation(input, 100L, "rpi-a", "device-a", true))
        assertTrue(addAggregationObservation(input, 101L, "rpi-b", "device-b", true))
        assertTrue(addAggregationObservation(input, 103L, "rpi-c", "device-c", true))
        assertTrue(addAggregationObservation(input, 104L, "rpi-d", "device-d", true))

        val bands = aggregateObservationsByBand(input, windowsPerBand = 4)

        assertTrue(bands.isSuccess)
        assertNull(bands.errorCode)
        assertEquals(2, bands.bandCount)

        val first = assertNotNull(bands.bandAt(0))
        assertEquals(25L, first.bandIndex)
        assertEquals(4, first.windowsPerBand)
        assertEquals(3, first.deviceCount)
        assertEquals(3, first.observationCount)

        val second = assertNotNull(bands.bandAt(1))
        assertEquals(26L, second.bandIndex)
        assertEquals(1, second.deviceCount)
        assertEquals(1, second.observationCount)
    }

    /**
     * Catches beid#154 at band scope. A band wider than one window is a
     * cross-window question, so its device count must come from the display id.
     */
    @Test
    fun bandDeviceCountUsesTheDisplayIdAcrossTheBandNotThePerWindowKey() {
        val input = createAggregationObservationInput()
        assertTrue(addAggregationObservation(input, 200L, "rpi-a1", "device-a", true))
        assertTrue(addAggregationObservation(input, 201L, "rpi-a2", "device-a", true))
        assertTrue(addAggregationObservation(input, 202L, "rpi-a3", "device-a", true))

        val bands = aggregateObservationsByBand(input, windowsPerBand = 4)

        assertEquals(1, bands.bandCount)
        val band = assertNotNull(bands.bandAt(0))
        assertEquals(50L, band.bandIndex)
        assertEquals(1, band.deviceCount)
        assertEquals(1, band.mutualDeviceCount)
        assertEquals(3, band.observationCount)
        assertEquals(0, band.observationsWithoutDisplayIdCount)
    }

    /**
     * Catches an implementation that echoes insertion order. Both platforms
     * must read the same series from the same observations regardless of the
     * order in which the native caller supplied them.
     */
    @Test
    fun outOfOrderInputProducesAnAscendingDeterministicSeries() {
        val input = createAggregationObservationInput()
        assertTrue(addAggregationObservation(input, 502L, "rpi-c", "device-c", true))
        assertTrue(addAggregationObservation(input, 500L, "rpi-a", "device-a", true))
        assertTrue(addAggregationObservation(input, 501L, "rpi-b", "device-b", true))

        val windows = aggregateObservationsByWindow(input)
        assertEquals(3, windows.windowCount)
        assertEquals(500L, assertNotNull(windows.windowAt(0)).windowIndex)
        assertEquals(501L, assertNotNull(windows.windowAt(1)).windowIndex)
        assertEquals(502L, assertNotNull(windows.windowAt(2)).windowIndex)

        val bands = aggregateObservationsByBand(input, windowsPerBand = 2)
        assertEquals(2, bands.bandCount)
        assertEquals(250L, assertNotNull(bands.bandAt(0)).bandIndex)
        assertEquals(251L, assertNotNull(bands.bandAt(1)).bandIndex)
    }

    /**
     * Catches deduplication, and catches a peer count that has silently become
     * an observation count. Two identical detections are two observations of one
     * peer; the two numbers answer different questions and must not collapse
     * into each other at either scope.
     */
    @Test
    fun repeatedIdenticalObservationsAreTwoObservationsOfOnePeer() {
        val input = createAggregationObservationInput()
        assertTrue(addAggregationObservation(input, 600L, "rpi-a", "device-a", true))
        assertTrue(addAggregationObservation(input, 600L, "rpi-a", "device-a", true))

        val windows = aggregateObservationsByWindow(input)
        assertEquals(1, windows.windowCount)
        val window = assertNotNull(windows.windowAt(0))
        assertEquals(2, window.observationCount)
        assertEquals(1, window.peerCount)
        assertEquals(2, window.mutualObservationCount)
        assertEquals(1, window.mutualPeerCount)

        val session = aggregateObservationsForSession(input, windowsPerBand = 4)
        assertEquals(2, session.observationCount)
        assertEquals(1, session.deviceCount)
        assertEquals(2, session.mutualObservationCount)
        assertEquals(1, session.mutualDeviceCount)

        val band = assertNotNull(session.bandAt(0))
        assertEquals(2, band.observationCount)
        assertEquals(1, band.deviceCount)
        assertEquals(2, band.mutualObservationCount)
        assertEquals(1, band.mutualDeviceCount)
    }

    /**
     * Catches an unlicensed display-id coverage count.
     *
     * Correction 2 makes the without-display-id count a contract field at each
     * scope: a consumer reads it to judge how much of that scope's device count
     * is actually covered. Every pair below is deliberately unequal, so a field
     * sourced from the wrong scope, or hardcoded to zero, fails here.
     *
     * The second band records only display-id-less observations. It still
     * appears, with a device count of zero. Absence means "nothing recorded",
     * which that band is not.
     */
    @Test
    fun observationsWithoutADisplayIdAreCountedPerScopeAtBandAndSessionTier() {
        val input = createAggregationObservationInput()
        assertTrue(addAggregationObservation(input, 100L, "rpi-a", "device-a", true))
        assertTrue(addAggregationObservation(input, 100L, "rpi-b", null, true))
        assertTrue(addAggregationObservation(input, 101L, "rpi-c", null, true))
        assertTrue(addAggregationObservation(input, 101L, "rpi-d", null, false))
        assertTrue(addAggregationObservation(input, 200L, "rpi-e", null, true))
        assertTrue(addAggregationObservation(input, 201L, "rpi-f", null, true))

        val session = aggregateObservationsForSession(input, windowsPerBand = 4)
        assertEquals(2, session.bandCount)

        val first = assertNotNull(session.bandAt(0))
        assertEquals(25L, first.bandIndex)
        assertEquals(1, first.deviceCount)
        assertEquals(4, first.observationCount)
        assertEquals(3, first.observationsWithoutDisplayIdCount)
        assertEquals(1, first.mutualDeviceCount)
        assertEquals(3, first.mutualObservationCount)
        assertEquals(2, first.mutualObservationsWithoutDisplayIdCount)

        val second = assertNotNull(session.bandAt(1))
        assertEquals(50L, second.bandIndex)
        assertEquals(0, second.deviceCount)
        assertEquals(2, second.observationCount)
        assertEquals(2, second.observationsWithoutDisplayIdCount)
        assertEquals(0, second.mutualDeviceCount)
        assertEquals(2, second.mutualObservationCount)
        assertEquals(2, second.mutualObservationsWithoutDisplayIdCount)

        assertEquals(1, session.deviceCount)
        assertEquals(6, session.observationCount)
        assertEquals(5, session.observationsWithoutDisplayIdCount)
        assertEquals(1, session.mutualDeviceCount)
        assertEquals(5, session.mutualObservationCount)
        assertEquals(4, session.mutualObservationsWithoutDisplayIdCount)
    }

    /**
     * Catches a silent clamp of an invalid band width. An empty series must
     * never be the way a caller learns its argument was rejected, because an
     * empty series legitimately means "no data".
     */
    @Test
    fun anInvalidBandWidthIsRejectedWithAnErrorCodeRatherThanAnEmptySeries() {
        val input = createAggregationObservationInput()
        assertTrue(addAggregationObservation(input, 700L, "rpi-a", "device-a", true))

        val zeroWidth = aggregateObservationsByBand(input, windowsPerBand = 0)
        assertFalse(zeroWidth.isSuccess)
        assertEquals("invalid_windows_per_band", zeroWidth.errorCode)
        assertEquals(0, zeroWidth.bandCount)

        val negativeWidth = aggregateObservationsByBand(input, windowsPerBand = -1)
        assertFalse(negativeWidth.isSuccess)
        assertEquals("invalid_windows_per_band", negativeWidth.errorCode)

        val session = aggregateObservationsForSession(input, windowsPerBand = 0)
        assertFalse(session.isSuccess)
        assertEquals("invalid_windows_per_band", session.errorCode)
        assertEquals(0, session.bandCount)
        assertEquals(0, session.windowCount)
        assertEquals(0, session.deviceCount)
        assertEquals(0, session.observationCount)
        assertEquals(0, session.observationsWithoutDisplayIdCount)
        assertEquals(0, session.mutualDeviceCount)
        assertEquals(0, session.mutualObservationCount)
        assertEquals(0, session.mutualObservationsWithoutDisplayIdCount)
    }

    /**
     * Catches a boundary that accepts anything. The shared boundary checks
     * null, length and shape only; it does not reach for platform APIs.
     *
     * The size bound is pinned on three axes, because its name spans more than
     * a single over-length ASCII fixture can prove: the UNIT is bytes and not
     * characters, the EDGE is inclusive, and the VALUE is written here as a
     * literal rather than by citing the production constant. Citing the
     * constant would move both sides of the comparison together and prove
     * nothing about what it is set to.
     */
    @Test
    fun theBoundaryRejectsNegativeWindowIndexesAndMalformedIdentifiers() {
        val input = createAggregationObservationInput()

        assertFalse(addAggregationObservation(input, -1L, "rpi-a", "device-a", true))
        assertFalse(addAggregationObservation(input, 800L, "", "device-a", true))
        assertFalse(addAggregationObservation(input, 800L, "rpi-a", "", true))
        assertFalse(
            addAggregationObservation(input, 800L, "a".repeat(4097), "device-a", true),
        )
        assertFalse(
            addAggregationObservation(input, 800L, "rpi-a", "a".repeat(4097), true),
        )
        assertFalse(
            addAggregationObservation(
                input,
                800L,
                charArrayOf(0xd800.toChar()).concatToString(),
                "device-a",
                true,
            ),
        )

        // The bound is a BYTE length, not a character count. This field is
        // comfortably under the bound in characters and three times over it in
        // bytes. The boundary deliberately does not constrain encoding, so a
        // native caller may legitimately supply a non-ASCII identifier, and the
        // two readings diverge by a factor of three for CJK.
        val underInCharactersOverInBytes = "あ".repeat(2000)
        assertEquals(2000, underInCharactersOverInBytes.length)
        assertEquals(6000, underInCharactersOverInBytes.encodeToByteArray().size)
        assertFalse(
            addAggregationObservation(input, 800L, underInCharactersOverInBytes, "device-a", true),
        )
        assertFalse(
            addAggregationObservation(input, 800L, "rpi-a", underInCharactersOverInBytes, true),
        )

        assertEquals(0, input.observationCount)

        // The edge is inclusive: exactly at the bound is accepted, so the rule
        // is at-most rather than strictly-less.
        val exactlyAtTheBound = "a".repeat(4096)
        assertEquals(4096, exactlyAtTheBound.encodeToByteArray().size)
        assertTrue(
            addAggregationObservation(input, 800L, exactlyAtTheBound, exactlyAtTheBound, true),
        )

        assertTrue(addAggregationObservation(input, 0L, "rpi-min", null, true))
        assertTrue(addAggregationObservation(input, Long.MAX_VALUE, "rpi-max", null, true))
        assertEquals(3, input.observationCount)
    }

    /**
     * Catches an implementation that treats "no observations" as a failure, or
     * that cannot distinguish an empty result from a rejected argument.
     */
    @Test
    fun emptyInputIsASuccessfulEmptySeriesNotAnError() {
        val input = createAggregationObservationInput()

        val windows = aggregateObservationsByWindow(input)
        assertEquals(0, windows.windowCount)

        val bands = aggregateObservationsByBand(input, windowsPerBand = 4)
        assertTrue(bands.isSuccess)
        assertNull(bands.errorCode)
        assertEquals(0, bands.bandCount)

        val session = aggregateObservationsForSession(input, windowsPerBand = 4)
        assertTrue(session.isSuccess)
        assertNull(session.errorCode)
        assertEquals(0, session.windowCount)
        assertEquals(0, session.bandCount)
        assertEquals(0, session.deviceCount)
        assertEquals(0, session.observationCount)
        assertEquals(0, session.observationsWithoutDisplayIdCount)
        assertEquals(0, session.mutualDeviceCount)
        assertEquals(0, session.mutualObservationCount)
        assertEquals(0, session.mutualObservationsWithoutDisplayIdCount)
    }

    /**
     * Catches a wiring mistake between the two scopes.
     *
     * Both scopes are reported at every tier because mutuality is not
     * determinable on-device today: a mutual-only API would report zeros for
     * every caller, and beid#154 needs the all-observations device count
     * specifically. Every pair below is deliberately different, so an
     * implementation that sources one scope from the other fails here.
     *
     * A window that recorded only non-mutual observations still appears, with
     * its mutual numbers at zero. Absence means "nothing recorded", which this
     * window is not.
     */
    @Test
    fun bothScopesAreReportedSideBySideAndNeitherBorrowsTheOthersNumbers() {
        val input = createAggregationObservationInput()
        assertTrue(addAggregationObservation(input, 100L, "rpi-a", "device-a", true))
        assertTrue(addAggregationObservation(input, 100L, "rpi-b", "device-b", false))
        assertTrue(addAggregationObservation(input, 101L, "rpi-a2", "device-a", true))
        assertTrue(addAggregationObservation(input, 101L, "rpi-c", null, false))
        assertTrue(addAggregationObservation(input, 102L, "rpi-d", "device-d", false))

        val session = aggregateObservationsForSession(input, windowsPerBand = 4)
        assertEquals(3, session.windowCount)

        val first = assertNotNull(session.windowAt(0))
        assertEquals(100L, first.windowIndex)
        assertEquals(2, first.peerCount)
        assertEquals(2, first.observationCount)
        assertEquals(1, first.mutualPeerCount)
        assertEquals(1, first.mutualObservationCount)

        val third = assertNotNull(session.windowAt(2))
        assertEquals(102L, third.windowIndex)
        assertEquals(1, third.peerCount)
        assertEquals(1, third.observationCount)
        assertEquals(0, third.mutualPeerCount)
        assertEquals(0, third.mutualObservationCount)

        assertEquals(1, session.bandCount)
        val band = assertNotNull(session.bandAt(0))
        assertEquals(25L, band.bandIndex)
        assertEquals(3, band.deviceCount)
        assertEquals(5, band.observationCount)
        assertEquals(1, band.observationsWithoutDisplayIdCount)
        assertEquals(1, band.mutualDeviceCount)
        assertEquals(2, band.mutualObservationCount)
        assertEquals(0, band.mutualObservationsWithoutDisplayIdCount)

        assertEquals(3, session.deviceCount)
        assertEquals(5, session.observationCount)
        assertEquals(1, session.observationsWithoutDisplayIdCount)
        assertEquals(1, session.mutualDeviceCount)
        assertEquals(2, session.mutualObservationCount)
        assertEquals(0, session.mutualObservationsWithoutDisplayIdCount)
    }

    /**
     * Catches an indexed accessor that traps instead of returning null off the
     * end of its series.
     *
     * The four indexed accessors are the contract's only way to read a series,
     * and they are published as returning a Swift optional. What comes back at
     * an out-of-range index is therefore behaviour a consumer relies on, not an
     * implementation detail: a caller walking a series must be able to stop on
     * null rather than crash. This covers the empty series and the failed
     * result too, where no index is valid at all.
     */
    @Test
    fun indexedAccessorsReturnNullOffTheEndOfTheirSeriesRatherThanTrapping() {
        val input = createAggregationObservationInput()
        assertTrue(addAggregationObservation(input, 900L, "rpi-a", "device-a", true))

        val windows = aggregateObservationsByWindow(input)
        assertEquals(1, windows.windowCount)
        assertNotNull(windows.windowAt(0))
        assertNull(windows.windowAt(1))
        assertNull(windows.windowAt(-1))
        assertNull(windows.windowAt(Int.MAX_VALUE))

        val bands = aggregateObservationsByBand(input, windowsPerBand = 4)
        assertEquals(1, bands.bandCount)
        assertNotNull(bands.bandAt(0))
        assertNull(bands.bandAt(1))
        assertNull(bands.bandAt(-1))
        assertNull(bands.bandAt(Int.MAX_VALUE))

        val session = aggregateObservationsForSession(input, windowsPerBand = 4)
        assertNotNull(session.windowAt(0))
        assertNull(session.windowAt(1))
        assertNull(session.windowAt(-1))
        assertNull(session.windowAt(Int.MAX_VALUE))
        assertNotNull(session.bandAt(0))
        assertNull(session.bandAt(1))
        assertNull(session.bandAt(-1))
        assertNull(session.bandAt(Int.MAX_VALUE))

        val emptySeries = aggregateObservationsForSession(
            createAggregationObservationInput(),
            windowsPerBand = 4,
        )
        assertEquals(0, emptySeries.windowCount)
        assertNull(emptySeries.windowAt(0))
        assertNull(emptySeries.bandAt(0))

        val rejected = aggregateObservationsForSession(input, windowsPerBand = 0)
        assertFalse(rejected.isSuccess)
        assertNull(rejected.windowAt(0))
        assertNull(rejected.bandAt(0))
    }

    /**
     * Catches an aggregate function that consumes or mutates its accumulator.
     *
     * The contract answers the recording screen's realtime question by stating
     * there is no subscription API: the caller holds one accumulator and
     * re-calls the aggregates as observations arrive. That prescribed usage
     * only works if aggregating is a read. A function that drained the
     * accumulator would return a perfectly correct first result and an empty
     * one from the second call onward, and every other vector in this file
     * would still pass.
     *
     * The tail of this test pins the other half of the same property: a result
     * is a snapshot, not a live view onto the accumulator.
     */
    @Test
    fun aggregatingIsAReadSoLaterCallsSeeLaterObservations() {
        val input = createAggregationObservationInput()
        assertTrue(addAggregationObservation(input, 700L, "rpi-a", "device-a", true))

        val firstSession = aggregateObservationsForSession(input, windowsPerBand = 4)
        assertEquals(1, firstSession.observationCount)
        assertEquals(1, input.observationCount)

        aggregateObservationsByWindow(input)
        aggregateObservationsByBand(input, windowsPerBand = 4)
        aggregateObservationsForSession(input, windowsPerBand = 4)
        assertEquals(1, input.observationCount)

        assertTrue(addAggregationObservation(input, 701L, "rpi-b", "device-b", true))
        assertEquals(2, input.observationCount)

        val secondSession = aggregateObservationsForSession(input, windowsPerBand = 4)
        assertEquals(2, secondSession.observationCount)
        assertEquals(2, secondSession.deviceCount)
        assertEquals(2, secondSession.mutualObservationCount)
        assertEquals(2, secondSession.windowCount)
        assertEquals(1, secondSession.bandCount)

        val windows = aggregateObservationsByWindow(input)
        assertEquals(2, windows.windowCount)
        val bands = aggregateObservationsByBand(input, windowsPerBand = 4)
        assertEquals(1, bands.bandCount)
        assertEquals(2, assertNotNull(bands.bandAt(0)).observationCount)

        assertEquals(1, firstSession.observationCount)
        assertEquals(1, firstSession.windowCount)
        assertEquals(1, assertNotNull(firstSession.bandAt(0)).observationCount)
    }

    /**
     * Catches an unbounded accumulator. The cap is a boundary check, not a
     * product rule, so it fails the add rather than corrupting a total.
     *
     * The cap is written here as a literal rather than by citing
     * `MAX_AGGREGATION_OBSERVATION_COUNT`. A vector that cites the constant
     * moves both sides of the comparison together, so it proves the cap is
     * enforced at whatever it happens to be set to and cannot notice the value
     * changing. The literal does not claim 100000 is a justified limit — it
     * mirrors the ledger constant and nothing measured it — it only makes a
     * silent change to that value visible.
     */
    @Test
    fun theAccumulatorRefusesObservationsBeyondItsCapacityCap() {
        val input = createAggregationObservationInput()
        repeat(100_000) { index ->
            assertTrue(addAggregationObservation(input, index.toLong(), "rpi-a", null, true))
        }
        assertEquals(100_000, input.observationCount)
        assertFalse(addAggregationObservation(input, 0L, "rpi-a", null, true))
        assertEquals(100_000, input.observationCount)
    }
}

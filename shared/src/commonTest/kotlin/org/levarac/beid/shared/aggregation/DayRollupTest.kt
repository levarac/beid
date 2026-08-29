package org.levarac.beid.shared.aggregation

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Vectors for the day-rollup family (gh#291): counting already-collected
 * native records that fall on "today", given a day boundary native resolves
 * from the device's actual calendar/timezone.
 *
 * Day-boundary invariant under test (see [DayRollupWindow]'s doc comment for
 * the full decision): a record belongs to the window `[start, end)` — a
 * half-open interval, inclusive of `start`, exclusive of `end`. The risky
 * edge case this file exists to pin down is a record whose timestamp lands
 * exactly on a day boundary: it must count in exactly one of two adjacent
 * days, never both, never neither.
 */
class DayRollupTest {

    @Test
    fun recordInsideTheWindowCounts() {
        val input = createDayRollupInput()
        addDayRollupRecord(input, recordIndex = 0, epochMillis = 1_000L)
        val window = requireNotNull(dayRollupWindow(startEpochMillisInclusive = 0L, endEpochMillisExclusive = 2_000L))

        val result = rollupRecordsForDay(input, window)

        assertEquals(1, result.recordCount)
        assertEquals(0, result.matchAt(0)?.recordIndex)
    }

    @Test
    fun recordBeforeTheWindowDoesNotCount() {
        val input = createDayRollupInput()
        addDayRollupRecord(input, recordIndex = 0, epochMillis = -1L)
        val window = requireNotNull(dayRollupWindow(startEpochMillisInclusive = 0L, endEpochMillisExclusive = 2_000L))

        val result = rollupRecordsForDay(input, window)

        assertEquals(0, result.recordCount)
    }

    @Test
    fun recordAtOrAfterTheWindowEndDoesNotCount() {
        val input = createDayRollupInput()
        addDayRollupRecord(input, recordIndex = 0, epochMillis = 2_000L)
        val window = requireNotNull(dayRollupWindow(startEpochMillisInclusive = 0L, endEpochMillisExclusive = 2_000L))

        val result = rollupRecordsForDay(input, window)

        assertEquals(0, result.recordCount)
    }

    /**
     * The exact instant at a shared boundary between two adjacent days must
     * count in the later day only. This is the specific case AGENTS.md's
     * timezone warning calls out: a naive inclusive-both-ends or
     * exclusive-both-ends comparison would double-count or drop this record.
     */
    @Test
    fun recordExactlyAtAMidnightBoundaryCountsInTheLaterDayOnly() {
        val dayOneEnd = 86_400_000L
        val input = createDayRollupInput()
        addDayRollupRecord(input, recordIndex = 0, epochMillis = dayOneEnd)

        val dayOneWindow = requireNotNull(
            dayRollupWindow(startEpochMillisInclusive = 0L, endEpochMillisExclusive = dayOneEnd)
        )
        val dayTwoWindow = requireNotNull(
            dayRollupWindow(startEpochMillisInclusive = dayOneEnd, endEpochMillisExclusive = dayOneEnd * 2)
        )

        assertEquals(0, rollupRecordsForDay(input, dayOneWindow).recordCount)
        assertEquals(1, rollupRecordsForDay(input, dayTwoWindow).recordCount)
    }

    /**
     * A "session spanning midnight" shape: two records either side of the
     * boundary, plus the boundary instant itself. Every record must be
     * counted in exactly one of the two adjacent windows — never both, never
     * neither.
     */
    @Test
    fun recordsAroundAMidnightBoundaryAreEachCountedExactlyOnce() {
        val dayOneEnd = 86_400_000L
        val input = createDayRollupInput()
        addDayRollupRecord(input, recordIndex = 0, epochMillis = dayOneEnd - 1L) // last ms of day one
        addDayRollupRecord(input, recordIndex = 1, epochMillis = dayOneEnd) // first ms of day two
        addDayRollupRecord(input, recordIndex = 2, epochMillis = dayOneEnd + 1L) // second ms of day two

        val dayOneWindow = requireNotNull(
            dayRollupWindow(startEpochMillisInclusive = 0L, endEpochMillisExclusive = dayOneEnd)
        )
        val dayTwoWindow = requireNotNull(
            dayRollupWindow(startEpochMillisInclusive = dayOneEnd, endEpochMillisExclusive = dayOneEnd * 2)
        )

        val dayOneResult = rollupRecordsForDay(input, dayOneWindow)
        val dayTwoResult = rollupRecordsForDay(input, dayTwoWindow)

        assertEquals(listOf(0), dayOneResult.matchingRecordIndices())
        assertEquals(listOf(1, 2), dayTwoResult.matchingRecordIndices())
    }

    @Test
    fun emptyInputCountsAsZeroRegardlessOfWindow() {
        val input = createDayRollupInput()
        val window = requireNotNull(dayRollupWindow(startEpochMillisInclusive = 0L, endEpochMillisExclusive = 1L))

        assertEquals(0, rollupRecordsForDay(input, window).recordCount)
    }

    @Test
    fun invertedOrEmptyWindowIsRejected() {
        assertNull(dayRollupWindow(startEpochMillisInclusive = 10L, endEpochMillisExclusive = 10L))
        assertNull(dayRollupWindow(startEpochMillisInclusive = 10L, endEpochMillisExclusive = 5L))
    }

    @Test
    fun matchingIndicesAreReportedInAscendingOrderRegardlessOfInsertionOrder() {
        val input = createDayRollupInput()
        addDayRollupRecord(input, recordIndex = 5, epochMillis = 500L)
        addDayRollupRecord(input, recordIndex = 2, epochMillis = 200L)
        addDayRollupRecord(input, recordIndex = 8, epochMillis = 800L)
        val window = requireNotNull(dayRollupWindow(startEpochMillisInclusive = 0L, endEpochMillisExclusive = 1_000L))

        val result = rollupRecordsForDay(input, window)

        assertEquals(listOf(2, 5, 8), result.matchingRecordIndices())
    }

    private fun DayRollupResult.matchingRecordIndices(): List<Int> =
        (0 until recordCount).map { position -> requireNotNull(matchAt(position)).recordIndex }
}

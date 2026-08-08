package org.levarac.beid.shared.event

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private const val EVENT_A = "00000000000000aa"
private const val EVENT_B = "00000000000000bb"

private fun parameters(
    recentWindowCount: Int = 3,
    minimumLeadingRelayCount: Int = 3,
    minimumLeadPercent: Int = 200,
): RelayMajorityParameters =
    assertNotNull(
        createRelayMajorityParameters(
            recentWindowCount = recentWindowCount,
            minimumLeadingRelayCount = minimumLeadingRelayCount,
            minimumLeadPercent = minimumLeadPercent,
        ),
    )

private fun inputOf(vararg rows: Triple<String, Long, Int>): RelayObservationInput {
    val input = createRelayObservationInput()
    rows.forEach { (hash, window, count) ->
        assertTrue(addRelayObservation(input, hash, window, count))
    }
    return input
}

class RelayMajorityTest {
    @Test
    fun noObservationsIsNotAClearMajority() {
        val verdict = evaluateRelayMajority(createRelayObservationInput(), parameters(), atWindowIndex = 10L)
        assertTrue(verdict.isSuccess)
        assertFalse(verdict.isMajorityClear)
        assertNull(verdict.leadingEventCodeHashHex)
        assertEquals(0, verdict.leadingRelayCount)
        assertEquals(0, verdict.runnerUpRelayCount)
    }

    @Test
    fun soleEventAtTheFloorIsAClearMajority() {
        val verdict = evaluateRelayMajority(
            inputOf(Triple(EVENT_A, 10L, 3)),
            parameters(),
            atWindowIndex = 10L,
        )
        assertTrue(verdict.isMajorityClear)
        assertEquals(EVENT_A, verdict.leadingEventCodeHashHex)
        assertEquals(3, verdict.leadingRelayCount)
        assertEquals(0, verdict.runnerUpRelayCount)
    }

    @Test
    fun soleEventBelowTheFloorIsNotAClearMajority() {
        val verdict = evaluateRelayMajority(
            inputOf(Triple(EVENT_A, 10L, 2)),
            parameters(),
            atWindowIndex = 10L,
        )
        assertFalse(verdict.isMajorityClear)
        assertEquals(2, verdict.leadingRelayCount)
    }

    @Test
    fun leaderAboveTheLeadPercentButBelowTheFloorIsNotClear() {
        val verdict = evaluateRelayMajority(
            inputOf(Triple(EVENT_A, 10L, 2), Triple(EVENT_B, 10L, 0)),
            parameters(),
            atWindowIndex = 10L,
        )
        assertFalse(verdict.isMajorityClear)
        assertEquals(2, verdict.leadingRelayCount)
        assertEquals(0, verdict.runnerUpRelayCount)
    }

    @Test
    fun leadExactlyAtTheLeadPercentIsClear() {
        val verdict = evaluateRelayMajority(
            inputOf(Triple(EVENT_A, 10L, 6), Triple(EVENT_B, 10L, 3)),
            parameters(),
            atWindowIndex = 10L,
        )
        assertTrue(verdict.isMajorityClear)
        assertEquals(EVENT_A, verdict.leadingEventCodeHashHex)
        assertEquals(6, verdict.leadingRelayCount)
        assertEquals(3, verdict.runnerUpRelayCount)
    }

    @Test
    fun leadJustBelowTheLeadPercentIsNotClear() {
        val verdict = evaluateRelayMajority(
            inputOf(Triple(EVENT_A, 10L, 5), Triple(EVENT_B, 10L, 3)),
            parameters(),
            atWindowIndex = 10L,
        )
        assertFalse(verdict.isMajorityClear)
        assertEquals(5, verdict.leadingRelayCount)
        assertEquals(3, verdict.runnerUpRelayCount)
    }

    @Test
    fun exactTieIsNotClear() {
        val verdict = evaluateRelayMajority(
            inputOf(Triple(EVENT_A, 10L, 4), Triple(EVENT_B, 10L, 4)),
            parameters(),
            atWindowIndex = 10L,
        )
        assertFalse(verdict.isMajorityClear)
        assertEquals(4, verdict.leadingRelayCount)
        assertEquals(4, verdict.runnerUpRelayCount)
    }

    @Test
    fun runnerUpAtZeroNeedsNoSpecialCase() {
        val verdict = evaluateRelayMajority(
            inputOf(Triple(EVENT_A, 10L, 4), Triple(EVENT_B, 10L, 0)),
            parameters(),
            atWindowIndex = 10L,
        )
        assertTrue(verdict.isMajorityClear)
        assertEquals(EVENT_A, verdict.leadingEventCodeHashHex)
    }

    /**
     * The vector that separates a maximum from a sum.
     *
     * `EVENT_A` is heard weakly in three consecutive windows; `EVENT_B` is heard
     * strongly in one. Summing counts one device once per window it was heard
     * in, so it inflates with dwell time and hands the lead to the weaker event.
     * The maximum keeps `EVENT_B` in front, which is the honest reading of the
     * evidence available.
     */
    @Test
    fun recentWindowsAreCombinedByMaximumNotBySum() {
        val verdict = evaluateRelayMajority(
            inputOf(
                Triple(EVENT_A, 8L, 2),
                Triple(EVENT_A, 9L, 2),
                Triple(EVENT_A, 10L, 2),
                Triple(EVENT_B, 10L, 5),
            ),
            parameters(),
            atWindowIndex = 10L,
        )
        assertEquals(EVENT_B, verdict.leadingEventCodeHashHex)
        assertEquals(5, verdict.leadingRelayCount)
        assertEquals(2, verdict.runnerUpRelayCount)
        assertTrue(verdict.isMajorityClear)
    }

    @Test
    fun observationsOlderThanTheRecentWindowsAreExcluded() {
        val verdict = evaluateRelayMajority(
            inputOf(Triple(EVENT_A, 5L, 100)),
            parameters(recentWindowCount = 3),
            atWindowIndex = 10L,
        )
        assertFalse(verdict.isMajorityClear)
        assertEquals(0, verdict.leadingRelayCount)
    }

    @Test
    fun theOldestIncludedWindowIsInsideTheRange() {
        val verdict = evaluateRelayMajority(
            inputOf(Triple(EVENT_A, 8L, 4)),
            parameters(recentWindowCount = 3),
            atWindowIndex = 10L,
        )
        assertTrue(verdict.isMajorityClear)
        assertEquals(4, verdict.leadingRelayCount)
    }

    @Test
    fun observationsAfterTheEvaluationWindowAreExcluded() {
        val verdict = evaluateRelayMajority(
            inputOf(Triple(EVENT_A, 11L, 9)),
            parameters(recentWindowCount = 3),
            atWindowIndex = 10L,
        )
        assertFalse(verdict.isMajorityClear)
        assertEquals(0, verdict.leadingRelayCount)
    }

    @Test
    fun duplicateEntriesForOneWindowResolveToTheMaximumInEitherOrder() {
        val ascending = evaluateRelayMajority(
            inputOf(Triple(EVENT_A, 10L, 2), Triple(EVENT_A, 10L, 7)),
            parameters(),
            atWindowIndex = 10L,
        )
        val descending = evaluateRelayMajority(
            inputOf(Triple(EVENT_A, 10L, 7), Triple(EVENT_A, 10L, 2)),
            parameters(),
            atWindowIndex = 10L,
        )
        assertEquals(7, ascending.leadingRelayCount)
        assertEquals(7, descending.leadingRelayCount)
    }

    @Test
    fun hashCaseDoesNotSplitAnEvent() {
        val input = createRelayObservationInput()
        assertTrue(addRelayObservation(input, EVENT_A.uppercase(), 10L, 4))
        assertTrue(addRelayObservation(input, EVENT_A, 10L, 6))
        assertEquals(1, input.eventCount)

        val verdict = evaluateRelayMajority(input, parameters(), atWindowIndex = 10L)
        assertEquals(EVENT_A, verdict.leadingEventCodeHashHex)
        assertEquals(6, verdict.leadingRelayCount)
    }

    @Test
    fun malformedObservationsAreRejected() {
        val input = createRelayObservationInput()
        assertFalse(addRelayObservation(input, "zzzzzzzzzzzzzzzz", 10L, 1))
        assertFalse(addRelayObservation(input, "", 10L, 1))
        assertFalse(addRelayObservation(input, EVENT_A, -1L, 1))
        assertFalse(addRelayObservation(input, EVENT_A, 10L, -1))
        assertEquals(0, input.eventCount)
    }

    @Test
    fun negativeEvaluationWindowFailsWholeRatherThanReturningNotClear() {
        val verdict = evaluateRelayMajority(
            inputOf(Triple(EVENT_A, 10L, 9)),
            parameters(),
            atWindowIndex = -1L,
        )
        assertFalse(verdict.isSuccess)
        assertEquals("invalid_window_index", verdict.errorCode)
        assertFalse(verdict.isMajorityClear)
        assertNull(verdict.leadingEventCodeHashHex)
    }

    @Test
    fun unusableParametersAreRejected() {
        assertNull(createRelayMajorityParameters(0, 3, 200))
        assertNull(createRelayMajorityParameters(3, 0, 200))
        assertNull(createRelayMajorityParameters(3, 3, 99))
    }

    @Test
    fun proposedDefaultsAreTheOnesDocumentedForSignOff() {
        val defaults = defaultRelayMajorityParameters()
        assertEquals(3, defaults.recentWindowCount)
        assertEquals(3, defaults.minimumLeadingRelayCount)
        assertEquals(200, defaults.minimumLeadPercent)
    }
}

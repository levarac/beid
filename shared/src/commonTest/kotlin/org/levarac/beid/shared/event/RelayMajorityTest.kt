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

    /**
     * The lead percentage's own admitted floor is where the tie rule was wrong.
     *
     * `createRelayMajorityParameters` rejects only *below* 100, so 100 is an
     * accepted setting. At 100 the lead test reduces to `leading * 100 >=
     * runnerUp * 100`, which any tie satisfies — so a dead tie above the relay
     * floor returned a clear majority with the winner picked by hash ascending.
     * An arbitrary tiebreak was deciding whether the app records without asking.
     *
     * A tie is the definition of a majority that is not clear, so it is rejected
     * explicitly rather than left to a parameter value to prevent.
     */
    @Test
    fun exactTieIsNotClearAtTheAdmittedLeadPercentFloor() {
        val verdict = evaluateRelayMajority(
            inputOf(Triple(EVENT_A, 10L, 5), Triple(EVENT_B, 10L, 5)),
            parameters(minimumLeadPercent = 100),
            atWindowIndex = 10L,
        )
        assertFalse(verdict.isMajorityClear)
        assertEquals(5, verdict.leadingRelayCount)
        assertEquals(5, verdict.runnerUpRelayCount)
    }

    /** The tie rule must not swallow a genuine one-relay lead at the same floor. */
    @Test
    fun strictlyAheadIsClearAtTheAdmittedLeadPercentFloor() {
        val verdict = evaluateRelayMajority(
            inputOf(Triple(EVENT_A, 10L, 6), Triple(EVENT_B, 10L, 5)),
            parameters(minimumLeadPercent = 100),
            atWindowIndex = 10L,
        )
        assertTrue(verdict.isMajorityClear)
        assertEquals(EVENT_A, verdict.leadingEventCodeHashHex)
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

    /**
     * The lead test multiplies, and in [Int] arithmetic it would wrap and invert.
     *
     * These two counts are chosen so the three implementations disagree:
     *
     * - `Long`: `21474835 * 100 = 2147483500` is not `>= 10737419 * 200 =
     *   2147483800`, so the majority is **not** clear. The leader is ahead but
     *   short of twice the runner-up.
     * - `Int`: the leader's product still fits, the runner-up's wraps to
     *   `-2147483496`, and a positive is trivially `>=` a negative — so an `Int`
     *   implementation calls it clear. It fails this test.
     * - The red implementation, which only asks whether the leader is ahead,
     *   also calls it clear. It fails this test too.
     *
     * The earlier version of this test used `Int.MAX_VALUE` against half of it,
     * which all three implementations answered the same way, so it asserted
     * nothing. Values that merely look extreme do not exercise an overflow; the
     * wrap has to change the answer.
     */
    @Test
    fun intMultiplicationWouldWrapAndInvertTheLeadTest() {
        val verdict = evaluateRelayMajority(
            inputOf(
                Triple(EVENT_A, 10L, 21_474_835),
                Triple(EVENT_B, 10L, 10_737_419),
            ),
            parameters(),
            atWindowIndex = 10L,
        )
        assertEquals(EVENT_A, verdict.leadingEventCodeHashHex)
        assertEquals(21_474_835, verdict.leadingRelayCount)
        assertEquals(10_737_419, verdict.runnerUpRelayCount)
        assertFalse(verdict.isMajorityClear)
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

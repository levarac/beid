package org.levarac.beid.navigation

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * JUnit port of iOS `HomeStandbyStateTests` (`ios/BeidTests/HomeStandbyStateTests.swift`,
 * PR #795). Times are uptime milliseconds; [s] keeps the iOS values readable.
 */
class HomeStandbyStateTest {
    private fun s(seconds: Long): Long = seconds * 1_000L

    @Test
    fun fallbackUsesTheThirtySecondBoundary() {
        val state = HomeStandbyState().update(isEnabled = true, hasCandidates = false, nowMillis = s(100))
        assertFalse(state.offersCodeEntry(atMillis = s(129)))
        assertFalse(state.offersCodeEntry(atMillis = s(130) - 1))
        assertTrue(state.offersCodeEntry(atMillis = s(130)))
    }

    @Test
    fun candidateArrivalCancelsAndRemovalRestartsTheInterval() {
        var state = HomeStandbyState()
        state = state.update(isEnabled = true, hasCandidates = false, nowMillis = s(100))
        state = state.update(isEnabled = true, hasCandidates = true, nowMillis = s(129))
        assertFalse(state.offersCodeEntry(atMillis = s(200)))
        state = state.update(isEnabled = true, hasCandidates = false, nowMillis = s(300))
        assertFalse(state.offersCodeEntry(atMillis = s(329)))
        assertTrue(state.offersCodeEntry(atMillis = s(330)))
    }

    @Test
    fun leavingHomeOrPausingDiscoveryDiscardsTheInterval() {
        var state = HomeStandbyState()
        state = state.update(isEnabled = true, hasCandidates = false, nowMillis = s(100))
        state = state.update(isEnabled = false, hasCandidates = false, nowMillis = s(129))
        assertFalse(state.offersCodeEntry(atMillis = s(500)))
        state = state.update(isEnabled = true, hasCandidates = false, nowMillis = s(600))
        assertFalse(state.offersCodeEntry(atMillis = s(629)))
        assertTrue(state.offersCodeEntry(atMillis = s(630)))
    }

    @Test
    fun repeatedUpdatesDoNotRestartAnUninterruptedInterval() {
        var state = HomeStandbyState()
        state = state.update(isEnabled = true, hasCandidates = false, nowMillis = s(100))
        state = state.update(isEnabled = true, hasCandidates = false, nowMillis = s(115))
        state = state.update(isEnabled = true, hasCandidates = false, nowMillis = s(129))
        assertTrue(state.offersCodeEntry(atMillis = s(130)))
        assertEquals(s(30), state.elapsedMillis(atMillis = s(130)))
    }

    @Test
    fun noFallbackBeforeDiscoveryBeginsOrWhileCandidatesExist() {
        var state = HomeStandbyState()
        assertFalse(state.offersCodeEntry(atMillis = s(300)))
        state = state.update(isEnabled = true, hasCandidates = true, nowMillis = s(100))
        assertFalse(state.offersCodeEntry(atMillis = s(300)))
        assertEquals(0L, state.elapsedMillis(atMillis = s(300)))
        assertNull(state.listeningStartedAtMillis)
    }

    @Test
    fun aClockReadingBeforeTheStartNeverYieldsNegativeElapsedTime() {
        val state = HomeStandbyState().update(isEnabled = true, hasCandidates = false, nowMillis = s(100))
        assertEquals(0L, state.elapsedMillis(atMillis = s(90)))
        assertFalse(state.offersCodeEntry(atMillis = s(90)))
    }
}

package org.levarac.beid.sensing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Vector-mirroring equivalence tests for beid#120 — reproduces the same
 * scenarios as `shared/src/commonTest/kotlin/org/levarac/beid/shared/sensing/ScanPhaseTest.kt`
 * against this Android adapter's own call boundary ([applyPhaseDecision],
 * [applyStartSensing], [applyStopSensing], [applySignalLost],
 * [applyResumeSensing]), so the same counts produce the same resulting
 * [ScanPhase] on Android as they do on iOS / in `shared` itself. This file
 * holds no phase-transition logic of its own to verify against — every
 * assertion below exercises the real call into
 * `org.levarac.beid.shared.sensing`.
 */
private const val THRESHOLD = 3
private val SESSION = ScanEventSession(eventCode = "ABC123")

private fun apply(
    currentPhase: ScanPhase,
    coPresentDeviceCount: Int,
    distinctDeviceCount: Int,
    distinctDeviceCountChanged: Boolean,
    eventConfirmThreshold: Int = THRESHOLD,
    session: ScanEventSession = SESSION,
): ScanPhase = applyPhaseDecision(
    currentPhase = currentPhase,
    session = session,
    coPresentDeviceCount = coPresentDeviceCount,
    distinctDeviceCount = distinctDeviceCount,
    distinctDeviceCountChanged = distinctDeviceCountChanged,
    eventConfirmThreshold = eventConfirmThreshold,
)

class ScanPhaseAdapterTest {

    // MARK: - IDLE / SIGNAL_LOST ignore detections

    @Test
    fun idleIgnoresDetectionsEvenWhenCountsWouldConfirm() {
        val result = apply(ScanPhase.Idle, THRESHOLD + 10, THRESHOLD + 10, distinctDeviceCountChanged = true)
        assertEquals(ScanPhase.Idle, result)
    }

    @Test
    fun signalLostIgnoresDetectionsEvenWhenCountsWouldConfirm() {
        val signalLost = ScanPhase.SignalLost(SESSION, peersVerified = 2)
        val result = apply(signalLost, THRESHOLD + 10, THRESHOLD + 10, distinctDeviceCountChanged = true)
        assertEquals(signalLost, result)
    }

    // MARK: - SENSING -> EVENT_FOUND, unconditionally

    @Test
    fun sensingMovesToEventFoundOnFirstDetectionEvenBelowThreshold() {
        val result = apply(ScanPhase.Sensing, coPresentDeviceCount = 1, distinctDeviceCount = 1, distinctDeviceCountChanged = true)
        assertEquals(ScanPhase.EventFound(SESSION), result)
    }

    @Test
    fun sensingCanCollapseStraightToRecordingWhenThresholdIsOne() {
        val result = apply(
            ScanPhase.Sensing,
            coPresentDeviceCount = 1,
            distinctDeviceCount = 1,
            distinctDeviceCountChanged = true,
            eventConfirmThreshold = 1,
        )
        assertEquals(ScanPhase.Recording(SESSION, peersVerified = 1), result)
    }

    // MARK: - EVENT_FOUND -> RECORDING, threshold-gated

    @Test
    fun eventFoundConfirmsExactlyAtThreshold() {
        val eventFound = ScanPhase.EventFound(SESSION)
        val result = apply(eventFound, coPresentDeviceCount = 0, distinctDeviceCount = THRESHOLD, distinctDeviceCountChanged = true)
        assertEquals(ScanPhase.Recording(SESSION, peersVerified = THRESHOLD), result)
    }

    @Test
    fun eventFoundStaysEventFoundOneBelowThreshold() {
        val eventFound = ScanPhase.EventFound(SESSION)
        val result = apply(
            eventFound,
            coPresentDeviceCount = THRESHOLD - 1,
            distinctDeviceCount = THRESHOLD - 1,
            distinctDeviceCountChanged = true,
        )
        assertEquals(eventFound, result)
    }

    @Test
    fun confirmationIsInsensitiveToWhichArmsCountReachedThresholdLast() {
        val eventFound = ScanPhase.EventFound(SESSION)
        val coPresenceArrivedLast = apply(
            eventFound,
            coPresentDeviceCount = THRESHOLD,
            distinctDeviceCount = THRESHOLD - 1,
            distinctDeviceCountChanged = true,
        )
        val distinctDeviceArrivedLast = apply(
            eventFound,
            coPresentDeviceCount = THRESHOLD - 1,
            distinctDeviceCount = THRESHOLD,
            distinctDeviceCountChanged = true,
        )
        assertTrue(coPresenceArrivedLast is ScanPhase.Recording)
        assertTrue(distinctDeviceArrivedLast is ScanPhase.Recording)
        assertEquals(coPresenceArrivedLast.kind(), distinctDeviceArrivedLast.kind())
    }

    /**
     * Mirrors shared's `oneLingeringDeviceNeverSatisfiesEitherArmNoMatterHowManyWindowsPass`.
     * One device, seen across many windows: co-presence is cleared every
     * window boundary by the caller (never above 1 here), and the distinct
     * count never grows past 1 for a single device.
     */
    @Test
    fun oneLingeringDeviceNeverSatisfiesEitherArmNoMatterHowManyWindowsPass() {
        val eventFound = ScanPhase.EventFound(SESSION)
        repeat(THRESHOLD + 5) {
            val result = apply(eventFound, coPresentDeviceCount = 1, distinctDeviceCount = 1, distinctDeviceCountChanged = true)
            assertEquals(eventFound, result, "window $it: a single lingering device must never confirm the event on its own")
        }
    }

    // MARK: - RECORDING updates, never re-confirms

    @Test
    fun recordingUpdatesWhenTheDistinctDeviceCountChanges() {
        val recording = ScanPhase.Recording(SESSION, peersVerified = THRESHOLD)
        val result = apply(
            recording,
            coPresentDeviceCount = THRESHOLD,
            distinctDeviceCount = THRESHOLD + 1,
            distinctDeviceCountChanged = true,
        )
        assertEquals(ScanPhase.Recording(SESSION, peersVerified = THRESHOLD + 1), result)
    }

    @Test
    fun recordingDoesNotUpdateOnADuplicateObservation() {
        val recording = ScanPhase.Recording(SESSION, peersVerified = THRESHOLD)
        val result = apply(
            recording,
            coPresentDeviceCount = THRESHOLD,
            distinctDeviceCount = THRESHOLD,
            distinctDeviceCountChanged = false,
        )
        assertEquals(recording, result)
    }

    @Test
    fun recordingIgnoresACoPresenceOnlyChangeThatDoesNotMoveTheDistinctDeviceCount() {
        val recording = ScanPhase.Recording(SESSION, peersVerified = THRESHOLD)
        val result = apply(
            recording,
            coPresentDeviceCount = THRESHOLD + 5,
            distinctDeviceCount = THRESHOLD,
            distinctDeviceCountChanged = false,
        )
        assertEquals(recording, result, "only the identified-device count moves the recorded value")
    }

    // MARK: - explicit actions: start / stop

    @Test
    fun startSensingAlwaysGoesToSensing() {
        assertEquals(ScanPhase.Sensing, applyStartSensing())
    }

    @Test
    fun stopSensingAlwaysGoesToIdle() {
        assertEquals(ScanPhase.Idle, applyStopSensing())
    }

    // MARK: - explicit actions: signal-loss / resume

    @Test
    fun signalLostAppliesOnlyFromRecording() {
        val recording = ScanPhase.Recording(SESSION, peersVerified = 2)
        val result = applySignalLost(recording)
        assertEquals(ScanPhase.SignalLost(SESSION, peersVerified = 2), result)
    }

    @Test
    fun signalLostIsANoOpFromEveryOtherPhase() {
        val phases = listOf(
            ScanPhase.Idle,
            ScanPhase.Sensing,
            ScanPhase.EventFound(SESSION),
            ScanPhase.SignalLost(SESSION, peersVerified = 1),
        )
        phases.forEach { phase ->
            assertEquals(phase, applySignalLost(phase), "signal-loss must be a no-op from $phase")
        }
    }

    @Test
    fun resumeSensingAppliesOnlyFromSignalLost() {
        val signalLost = ScanPhase.SignalLost(SESSION, peersVerified = 2)
        val result = applyResumeSensing(signalLost)
        assertEquals(ScanPhase.Recording(SESSION, peersVerified = 2), result)
    }

    @Test
    fun resumeSensingIsANoOpFromEveryOtherPhase() {
        val phases = listOf(
            ScanPhase.Idle,
            ScanPhase.Sensing,
            ScanPhase.EventFound(SESSION),
            ScanPhase.Recording(SESSION, peersVerified = 1),
        )
        phases.forEach { phase ->
            assertEquals(phase, applyResumeSensing(phase), "resume must be a no-op from $phase")
        }
    }

    /**
     * Resume followed by a duplicate detection round-trips to the same
     * `RECORDING` state without re-confirming.
     */
    @Test
    fun resumingFromSignalLostThenReObservingTheSameCountsDoesNotReconfirm() {
        val signalLost = ScanPhase.SignalLost(SESSION, peersVerified = THRESHOLD)
        val resumed = applyResumeSensing(signalLost)
        assertEquals(ScanPhase.Recording(SESSION, peersVerified = THRESHOLD), resumed)

        val redetected = apply(
            resumed,
            coPresentDeviceCount = THRESHOLD,
            distinctDeviceCount = THRESHOLD,
            distinctDeviceCountChanged = false,
        )
        assertEquals(ScanPhase.Recording(SESSION, peersVerified = THRESHOLD), redetected)
    }
}

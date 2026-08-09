package org.levarac.beid.shared.sensing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

private const val THRESHOLD = 3

class ScanPhaseTest {

    // MARK: - hasEnoughCoPresentDevicesToConfirmScanEvent / hasEnoughDistinctDevicesToConfirmScanEvent

    @Test
    fun coPresenceArmExactlyAtThresholdConfirms() {
        assertTrue(hasEnoughCoPresentDevicesToConfirmScanEvent(THRESHOLD, THRESHOLD))
    }

    @Test
    fun coPresenceArmOneBelowThresholdDoesNotConfirm() {
        assertFalse(hasEnoughCoPresentDevicesToConfirmScanEvent(THRESHOLD - 1, THRESHOLD))
    }

    @Test
    fun distinctDeviceArmExactlyAtThresholdConfirms() {
        assertTrue(hasEnoughDistinctDevicesToConfirmScanEvent(THRESHOLD, THRESHOLD))
    }

    @Test
    fun distinctDeviceArmOneBelowThresholdDoesNotConfirm() {
        assertFalse(hasEnoughDistinctDevicesToConfirmScanEvent(THRESHOLD - 1, THRESHOLD))
    }

    // MARK: - shouldConfirmScanEvent: the disjunction

    @Test
    fun coPresenceArmAloneSatisfiesTheDisjunction() {
        assertTrue(
            shouldConfirmScanEvent(
                coPresentDeviceCount = THRESHOLD,
                distinctDeviceCount = 0,
                eventConfirmThreshold = THRESHOLD,
            ),
        )
    }

    @Test
    fun distinctDeviceArmAloneSatisfiesTheDisjunction() {
        assertTrue(
            shouldConfirmScanEvent(
                coPresentDeviceCount = 0,
                distinctDeviceCount = THRESHOLD,
                eventConfirmThreshold = THRESHOLD,
            ),
        )
    }

    @Test
    fun neitherArmSatisfiesTheDisjunction() {
        assertFalse(
            shouldConfirmScanEvent(
                coPresentDeviceCount = THRESHOLD - 1,
                distinctDeviceCount = THRESHOLD - 1,
                eventConfirmThreshold = THRESHOLD,
            ),
        )
    }

    /**
     * Mirrors iOS's `testOneLingeringDeviceNeverSatisfiesTheConfirmThresholdOnItsOwn`
     * (`ios/BeidTests/DeviceCountTests.swift`). One device, seen across many
     * windows: the co-presence count is cleared every window boundary by the
     * caller (never passed in above 1 here), and the distinct-device count
     * never grows past 1 for a single device. Neither arm may accumulate with
     * dwell time on its own.
     */
    @Test
    fun oneLingeringDeviceNeverSatisfiesEitherArmNoMatterHowManyWindowsPass() {
        repeat(THRESHOLD + 5) {
            assertFalse(
                shouldConfirmScanEvent(
                    coPresentDeviceCount = 1,
                    distinctDeviceCount = 1,
                    eventConfirmThreshold = THRESHOLD,
                ),
                "window $it: a single lingering device must never confirm the event on its own",
            )
        }
    }

    // MARK: - applyScanDetection: IDLE / SIGNAL_LOST ignore detections

    @Test
    fun idleIgnoresDetectionsEvenWhenCountsWouldConfirm() {
        val result = applyScanDetection(
            currentPhase = ScanPhaseKind.IDLE,
            coPresentDeviceCount = THRESHOLD + 10,
            distinctDeviceCount = THRESHOLD + 10,
            distinctDeviceCountChanged = true,
            eventConfirmThreshold = THRESHOLD,
        )
        assertEquals(ScanPhaseKind.IDLE, result.resultingPhase)
        assertFalse(result.transitionedToEventFound)
        assertFalse(result.confirmedEvent)
        assertFalse(result.updatedRecording)
    }

    /**
     * A detection arriving while `.signalLost` is a no-op — recovery is only
     * ever the explicit `scanPhaseAfterResumeSensing()` action, never
     * automatic on the next detection.
     */
    @Test
    fun signalLostIgnoresDetectionsEvenWhenCountsWouldConfirm() {
        val result = applyScanDetection(
            currentPhase = ScanPhaseKind.SIGNAL_LOST,
            coPresentDeviceCount = THRESHOLD + 10,
            distinctDeviceCount = THRESHOLD + 10,
            distinctDeviceCountChanged = true,
            eventConfirmThreshold = THRESHOLD,
        )
        assertEquals(ScanPhaseKind.SIGNAL_LOST, result.resultingPhase)
        assertFalse(result.transitionedToEventFound)
        assertFalse(result.confirmedEvent)
        assertFalse(result.updatedRecording)
    }

    // MARK: - applyScanDetection: SENSING -> EVENT_FOUND, unconditionally

    @Test
    fun sensingMovesToEventFoundOnFirstDetectionEvenBelowThreshold() {
        val result = applyScanDetection(
            currentPhase = ScanPhaseKind.SENSING,
            coPresentDeviceCount = 1,
            distinctDeviceCount = 1,
            distinctDeviceCountChanged = true,
            eventConfirmThreshold = THRESHOLD,
        )
        assertEquals(ScanPhaseKind.EVENT_FOUND, result.resultingPhase)
        assertTrue(result.transitionedToEventFound)
        assertFalse(result.confirmedEvent)
        assertFalse(result.updatedRecording)
    }

    /**
     * With `eventConfirmThreshold == 1` (only reachable via the DEBUG
     * `-beid-threshold-override` launch argument today), the very first
     * detection both moves `.sensing -> .eventFound` and immediately
     * confirms — matching iOS's `handleDetection` calling `beginEventFound`
     * then `observe` for the same detection.
     */
    @Test
    fun sensingCanCollapseStraightToRecordingWhenThresholdIsOne() {
        val result = applyScanDetection(
            currentPhase = ScanPhaseKind.SENSING,
            coPresentDeviceCount = 1,
            distinctDeviceCount = 1,
            distinctDeviceCountChanged = true,
            eventConfirmThreshold = 1,
        )
        assertEquals(ScanPhaseKind.RECORDING, result.resultingPhase)
        assertTrue(result.transitionedToEventFound)
        assertTrue(result.confirmedEvent)
        assertFalse(result.updatedRecording)
    }

    // MARK: - applyScanDetection: EVENT_FOUND -> RECORDING, threshold-gated

    @Test
    fun eventFoundConfirmsExactlyAtThreshold() {
        val result = applyScanDetection(
            currentPhase = ScanPhaseKind.EVENT_FOUND,
            coPresentDeviceCount = 0,
            distinctDeviceCount = THRESHOLD,
            distinctDeviceCountChanged = true,
            eventConfirmThreshold = THRESHOLD,
        )
        assertEquals(ScanPhaseKind.RECORDING, result.resultingPhase)
        assertFalse(result.transitionedToEventFound)
        assertTrue(result.confirmedEvent)
    }

    @Test
    fun eventFoundStaysEventFoundOneBelowThreshold() {
        val result = applyScanDetection(
            currentPhase = ScanPhaseKind.EVENT_FOUND,
            coPresentDeviceCount = THRESHOLD - 1,
            distinctDeviceCount = THRESHOLD - 1,
            distinctDeviceCountChanged = true,
            eventConfirmThreshold = THRESHOLD,
        )
        assertEquals(ScanPhaseKind.EVENT_FOUND, result.resultingPhase)
        assertFalse(result.confirmedEvent)
    }

    /**
     * The reducer is a pure function of the counts supplied for this call,
     * not of how those counts were assembled — feeding the same final counts
     * through two differently-ordered detection sequences must confirm the
     * same way. (Which underlying observation happened first is a
     * native/aggregation-family concern this reducer does not see.)
     */
    @Test
    fun confirmationIsInsensitiveToWhichArmsCountReachedThresholdLast() {
        val coPresenceArrivedLast = applyScanDetection(
            currentPhase = ScanPhaseKind.EVENT_FOUND,
            coPresentDeviceCount = THRESHOLD,
            distinctDeviceCount = THRESHOLD - 1,
            distinctDeviceCountChanged = true,
            eventConfirmThreshold = THRESHOLD,
        )
        val distinctDeviceArrivedLast = applyScanDetection(
            currentPhase = ScanPhaseKind.EVENT_FOUND,
            coPresentDeviceCount = THRESHOLD - 1,
            distinctDeviceCount = THRESHOLD,
            distinctDeviceCountChanged = true,
            eventConfirmThreshold = THRESHOLD,
        )
        assertTrue(coPresenceArrivedLast.confirmedEvent)
        assertTrue(distinctDeviceArrivedLast.confirmedEvent)
        assertEquals(coPresenceArrivedLast.resultingPhase, distinctDeviceArrivedLast.resultingPhase)
    }

    // MARK: - applyScanDetection: RECORDING updates, never re-confirms

    @Test
    fun recordingUpdatesWhenTheDistinctDeviceCountChanges() {
        val result = applyScanDetection(
            currentPhase = ScanPhaseKind.RECORDING,
            coPresentDeviceCount = THRESHOLD,
            distinctDeviceCount = THRESHOLD + 1,
            distinctDeviceCountChanged = true,
            eventConfirmThreshold = THRESHOLD,
        )
        assertEquals(ScanPhaseKind.RECORDING, result.resultingPhase)
        assertFalse(result.transitionedToEventFound)
        assertFalse(result.confirmedEvent, "already recording: crossing the threshold again is not new information")
        assertTrue(result.updatedRecording)
    }

    /**
     * A duplicate observation (the same device seen again) does not move
     * `distinctDeviceCount`, so it must not re-publish a recording update —
     * mirrors iOS's `observe` only calling `updateRecording` when
     * `deviceCountChanged`.
     */
    @Test
    fun recordingDoesNotUpdateOnADuplicateObservation() {
        val result = applyScanDetection(
            currentPhase = ScanPhaseKind.RECORDING,
            coPresentDeviceCount = THRESHOLD,
            distinctDeviceCount = THRESHOLD,
            distinctDeviceCountChanged = false,
            eventConfirmThreshold = THRESHOLD,
        )
        assertEquals(ScanPhaseKind.RECORDING, result.resultingPhase)
        assertFalse(result.updatedRecording)
    }

    @Test
    fun recordingIgnoresACoPresenceOnlyChangeThatDoesNotMoveTheDistinctDeviceCount() {
        val result = applyScanDetection(
            currentPhase = ScanPhaseKind.RECORDING,
            coPresentDeviceCount = THRESHOLD + 5,
            distinctDeviceCount = THRESHOLD,
            distinctDeviceCountChanged = false,
            eventConfirmThreshold = THRESHOLD,
        )
        assertFalse(result.updatedRecording, "only the identified-device count moves the recorded value")
    }

    // MARK: - explicit actions: start / stop

    @Test
    fun startSensingAlwaysGoesToSensing() {
        assertEquals(ScanPhaseKind.SENSING, scanPhaseAfterStartSensing())
    }

    @Test
    fun stopSensingAlwaysGoesToIdle() {
        assertEquals(ScanPhaseKind.IDLE, scanPhaseAfterStopSensing())
    }

    // MARK: - explicit actions: signal-loss / resume

    @Test
    fun signalLostAppliesOnlyFromRecording() {
        val result = scanPhaseAfterSignalLost(ScanPhaseKind.RECORDING)
        assertTrue(result.applied)
        assertEquals(ScanPhaseKind.SIGNAL_LOST, result.resultingPhase)
    }

    @Test
    fun signalLostIsANoOpFromEveryOtherPhase() {
        listOf(ScanPhaseKind.IDLE, ScanPhaseKind.SENSING, ScanPhaseKind.EVENT_FOUND, ScanPhaseKind.SIGNAL_LOST)
            .forEach { phase ->
                val result = scanPhaseAfterSignalLost(phase)
                assertFalse(result.applied, "signal-loss must be a no-op from $phase")
                assertEquals(phase, result.resultingPhase)
            }
    }

    @Test
    fun resumeSensingAppliesOnlyFromSignalLost() {
        val result = scanPhaseAfterResumeSensing(ScanPhaseKind.SIGNAL_LOST)
        assertTrue(result.applied)
        assertEquals(ScanPhaseKind.RECORDING, result.resultingPhase)
    }

    @Test
    fun resumeSensingIsANoOpFromEveryOtherPhase() {
        listOf(ScanPhaseKind.IDLE, ScanPhaseKind.SENSING, ScanPhaseKind.EVENT_FOUND, ScanPhaseKind.RECORDING)
            .forEach { phase ->
                val result = scanPhaseAfterResumeSensing(phase)
                assertFalse(result.applied, "resume must be a no-op from $phase")
                assertEquals(phase, result.resultingPhase)
            }
    }

    /**
     * Resume followed by a duplicate detection round-trips to the same
     * `RECORDING` state without re-confirming — the recovery vector from
     * beid#116's acceptance criteria (`signal loss からの復帰`).
     */
    @Test
    fun resumingFromSignalLostThenReObservingTheSameCountsDoesNotReconfirm() {
        val resumed = scanPhaseAfterResumeSensing(ScanPhaseKind.SIGNAL_LOST)
        assertTrue(resumed.applied)

        val redetected = applyScanDetection(
            currentPhase = resumed.resultingPhase,
            coPresentDeviceCount = THRESHOLD,
            distinctDeviceCount = THRESHOLD,
            distinctDeviceCountChanged = false,
            eventConfirmThreshold = THRESHOLD,
        )
        assertEquals(ScanPhaseKind.RECORDING, redetected.resultingPhase)
        assertFalse(redetected.confirmedEvent)
        assertFalse(redetected.updatedRecording)
    }
}

package org.levarac.beid.shared.sensing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Proves `org.levarac.beid.shared.sensing` compiles and runs from the
 * Android host, per the walking-skeleton pattern (§3 step 5 of
 * `docs/kmp-shared-foundation.md`).
 *
 * **This is not a production caller.** `android/app`'s only screen today,
 * `EventJoinCoordinator`, has no phase concept beyond
 * `Idle`/`RequestingPermission`/`Sensing`/`PermissionDenied` — there is no
 * Android production code path that reaches `.eventFound`/`.recording`/
 * `.signalLost` yet. Wiring an Android caller for this family is beid#117's
 * child #120 (the Android sensing UI), not this issue's scope.
 */
class ScanPhaseAndroidHostTest {
    @Test
    fun androidCanEvaluateTheConfirmDisjunction() {
        assertTrue(
            shouldConfirmScanEvent(coPresentDeviceCount = 3, distinctDeviceCount = 0, eventConfirmThreshold = 3),
        )
        assertFalse(
            shouldConfirmScanEvent(coPresentDeviceCount = 2, distinctDeviceCount = 2, eventConfirmThreshold = 3),
        )
    }

    @Test
    fun androidCanDriveTheFullPhaseSequence() {
        var phase = scanPhaseAfterStartSensing()
        assertEquals(ScanPhaseKind.SENSING, phase)

        val detected = applyScanDetection(
            currentPhase = phase,
            coPresentDeviceCount = 1,
            distinctDeviceCount = 1,
            distinctDeviceCountChanged = true,
            eventConfirmThreshold = 3,
        )
        assertEquals(ScanPhaseKind.EVENT_FOUND, detected.resultingPhase)
        phase = detected.resultingPhase

        val confirmed = applyScanDetection(
            currentPhase = phase,
            coPresentDeviceCount = 3,
            distinctDeviceCount = 3,
            distinctDeviceCountChanged = true,
            eventConfirmThreshold = 3,
        )
        assertTrue(confirmed.confirmedEvent)
        phase = confirmed.resultingPhase
        assertEquals(ScanPhaseKind.RECORDING, phase)

        val lost = scanPhaseAfterSignalLost(phase)
        assertTrue(lost.applied)
        phase = lost.resultingPhase
        assertEquals(ScanPhaseKind.SIGNAL_LOST, phase)

        val resumed = scanPhaseAfterResumeSensing(phase)
        assertTrue(resumed.applied)
        assertEquals(ScanPhaseKind.RECORDING, resumed.resultingPhase)

        assertEquals(ScanPhaseKind.IDLE, scanPhaseAfterStopSensing())
    }
}

package org.levarac.beid.sensing

import kotlinx.coroutines.flow.StateFlow

/**
 * The narrow surface [EventJoinViewModel][org.levarac.beid.ui.screens.EventJoinViewModel]
 * needs from a join session — [EventJoinCoordinator]'s production
 * implementation, or a fake in tests. Exists because [EventJoinCoordinator]
 * itself requires a real `Activity` and eagerly constructs a real
 * `BarnardEngine`, which makes it unconstructable in a plain JVM test. This
 * interface deliberately excludes `onRequestPermissionsResult`/`dispose`/
 * engine construction — those stay Activity-lifecycle glue, called directly
 * by `MainActivity`, not a ViewModel concern.
 */
interface EventJoinSession {
    val state: StateFlow<EventJoinUiState>

    fun joinEvent(code: String)

    fun openAppSettings()

    /**
     * Manual trigger for `RECORDING -> SIGNAL_LOST` (beid#120) — Android has
     * no real BLE signal-loss *detection* yet, only this explicit action,
     * mirroring iOS's `SensingCoordinator.simulateSignalLost()`. A no-op
     * unless the current [EventJoinUiState.Sensing] phase is
     * [ScanPhase.Recording].
     */
    fun simulateSignalLost()

    /**
     * Resumes `SIGNAL_LOST -> RECORDING` in place — never a restart, so
     * nothing already recorded is discarded. Mirrors iOS's
     * `SensingCoordinator.resumeSensing()`. A no-op unless the current
     * [EventJoinUiState.Sensing] phase is [ScanPhase.SignalLost].
     */
    fun resumeSensing()
}

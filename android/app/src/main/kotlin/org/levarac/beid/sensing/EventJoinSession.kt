package org.levarac.beid.sensing

import kotlinx.coroutines.flow.StateFlow

/**
 * A nearby beacon candidate. Its name is an unauthenticated B005 announcement;
 * the optional ID and period exist only after the shared reducer accepts the
 * OPEN definition, its hash binding, and the operator lookup route.
 */
data class NearbyEventCard(
    val beaconDisplayName: String?,
    val eventIdHex: String? = null,
    val validFromEpochSeconds: Long? = null,
    val validUntilEpochSeconds: Long? = null,
    /** Stable B005 candidate identity; unlike list position, it survives reordering. */
    val eventCodeHashHex: String,
)

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

    /** Every nearby candidate is displayable; only cards with an Event ID are joinable. */
    val nearbyEventCards: StateFlow<List<NearbyEventCard>>

    fun joinEvent(code: String)

    /** Starts the existing native join sequence with the shared-verified Event ID verbatim. */
    fun joinNearbyEvent(eventIdHex: String)

    fun openAppSettings()

    /**
     * Triggers the real Android runtime-permission flow for BLE
     * (BLUETOOTH_SCAN/CONNECT/ADVERTISE) — the same underlying
     * `engine.requestPermissions` call [joinEvent] makes — so onboarding's
     * "Allow Bluetooth" CTA (`BluetoothPermissionScreen`) actually produces
     * the OS prompt its copy promises, instead of being purely cosmetic.
     *
     * Deliberately does not branch on the resulting `BarnardPermissionResult`
     * granted/denied content: onboarding routing after this call is
     * radio-power-only ([BluetoothRadioMonitor.isOn]), mirroring iOS's
     * `evaluateBluetoothState()`, which likewise never consults permission
     * grant/denial when deciding where to route. A denied-permission
     * onboarding state is out of scope here; `EventJoinUiState.PermissionDenied`
     * on the join screen already covers a hard denial reached later.
     */
    fun requestBluetoothPermission(onComplete: () -> Unit)

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

    /**
     * Leaves the currently-joined event — the Account screen's "Leave Event"
     * action (beid#126). Mirrors iOS's `SensingCoordinator.leaveEvent()`
     * (`engine.leaveEvent()` + resetting `joinedEventCode`), adapted for this
     * session's richer local state (a [ScanPhase] and device-accounting
     * bookkeeping iOS's simple `joinedEventCode: String?` doesn't carry): the
     * production implementation calls the SDK's `leaveEvent()` and then
     * resets native bookkeeping back to [EventJoinUiState.Idle] so the UI
     * reflects "no active session" afterward. Callers gate this action's
     * availability on session activity themselves — see [state].
     */
    fun leaveEvent()
}

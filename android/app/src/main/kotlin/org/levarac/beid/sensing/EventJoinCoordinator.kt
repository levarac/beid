package org.levarac.beid.sensing

import android.app.Activity
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.levarac.barnard.BarnardEngine
import org.levarac.barnard.BarnardEvent
import org.levarac.barnard.BarnardPermissionResult

/**
 * UI-facing state for [EventJoinCoordinator]. Mirrors the shape of iOS's
 * `SensingCoordinator` phases (`ios/Beid/Sensing/SensingCoordinator.swift`).
 * [Sensing] carries the native [ScanPhase] driven by
 * `org.levarac.beid.shared.sensing` (beid#116/#120) once the event join
 * succeeds — see [EventJoinCoordinator]'s detection handling.
 */
sealed class EventJoinUiState {
    data object Idle : EventJoinUiState()
    data object RequestingPermission : EventJoinUiState()
    data class Sensing(val phase: ScanPhase) : EventJoinUiState()
    data object PermissionDenied : EventJoinUiState()
    data object JoinFailed : EventJoinUiState()
}

/**
 * Maps a resolved [BarnardPermissionResult] to the [EventJoinUiState] it
 * produces when the request did not end in a full grant. Callers are
 * expected to handle the "granted with full scan+advertise capability"
 * case themselves before reaching here (it carries side effects — starting
 * the join — that this pure function must not perform), so a fully-granted
 * [BarnardPermissionResult.Granted] is out of this function's contract.
 *
 * [BarnardPermissionResult.Failed] (SDK-reported `E_NO_ACTIVITY` or
 * `E_PERMISSION_REQUEST_IN_PROGRESS`, per decompiled Barnard 0.3.0) is a
 * caller/lifecycle failure, never a permission denial, so it maps to
 * [EventJoinUiState.JoinFailed] rather than [EventJoinUiState.PermissionDenied]
 * (see issue #127).
 */
fun mapPermissionResultToState(result: BarnardPermissionResult): EventJoinUiState = when (result) {
    is BarnardPermissionResult.Granted -> EventJoinUiState.PermissionDenied
    is BarnardPermissionResult.Failed -> EventJoinUiState.JoinFailed
}

/**
 * Wraps [BarnardEngine] (permission request → `joinEvent` → `startAuto`)
 * behind the native [ScanPhase] state machine driven by
 * `org.levarac.beid.shared.sensing` (beid#116/#120) — the Android
 * counterpart of iOS's `SensingCoordinator`, scoped to this app's one
 * screen. This adapter holds no threshold or transition-graph logic of its
 * own; every phase decision is a single call into [applyPhaseDecision] or
 * one of the explicit-action functions in `ScanPhase.kt`.
 */
class EventJoinCoordinator(private val activity: Activity) : EventJoinSession {
    private val engine = BarnardEngine(activity.applicationContext).apply {
        setActivity(activity)
        onEvent = ::handleBarnardEvent
    }

    private val accounting = ScanDeviceAccounting()

    private val _state = MutableStateFlow<EventJoinUiState>(EventJoinUiState.Idle)
    override val state: StateFlow<EventJoinUiState> = _state.asStateFlow()

    /** Source of truth for the current [ScanPhase] — mirrors [_state]'s payload once `Sensing` is reached. */
    private var scanPhase: ScanPhase = ScanPhase.Idle

    override fun joinEvent(code: String) {
        _state.value = EventJoinUiState.RequestingPermission
        engine.requestPermissions { result ->
            if (result is BarnardPermissionResult.Granted && result.status.canScan && result.status.canAdvertise) {
                engine.joinEvent(code)
                engine.startAuto()
                startSensing()
            } else {
                _state.value = mapPermissionResultToState(result)
            }
        }
    }

    private fun startSensing() {
        accounting.reset()
        scanPhase = applyStartSensing()
        _state.value = EventJoinUiState.Sensing(scanPhase)
    }

    private fun handleBarnardEvent(event: BarnardEvent) {
        val detection = (event as? BarnardEvent.Detection)?.detection ?: return
        handleDetection(enin = detection.enin, rpid = detection.rpid, detectedDisplayId = detection.detectedDisplayId)
    }

    /**
     * Mirrors iOS's `SensingCoordinator.handleDetection(enin:rpid:detectedDisplayId:)`.
     * Runs the native counting bookkeeping unconditionally, then calls
     * through to [applyPhaseDecision] regardless of [scanPhase] — `IDLE`/
     * `SIGNAL_LOST` are not special-cased out here; `applyScanDetection`
     * (beid#116) already reports those as no-ops via its result flags, and
     * duplicating that "ignore" branch natively would be exactly the kind
     * of re-derived transition AGENTS.md's ownership boundary forbids.
     */
    private fun handleDetection(enin: Long, rpid: String, detectedDisplayId: String?) {
        val distinctDeviceCountChanged = accounting.record(enin = enin, rpid = rpid, detectedDisplayId = detectedDisplayId)

        val session = when (val phase = scanPhase) {
            is ScanPhase.EventFound -> phase.session
            is ScanPhase.Recording -> phase.session
            is ScanPhase.SignalLost -> phase.session
            ScanPhase.Sensing -> ScanEventSession(eventCode = engine.getCurrentEventCode() ?: UNKNOWN_EVENT_CODE)
            ScanPhase.Idle -> ScanEventSession(eventCode = UNKNOWN_EVENT_CODE)
        }

        scanPhase = applyPhaseDecision(
            currentPhase = scanPhase,
            session = session,
            coPresentDeviceCount = accounting.coPresentDeviceCount,
            distinctDeviceCount = accounting.distinctDeviceCount,
            distinctDeviceCountChanged = distinctDeviceCountChanged,
            eventConfirmThreshold = BeidConfig.eventConfirmThreshold,
        )
        _state.value = EventJoinUiState.Sensing(scanPhase)
    }

    override fun simulateSignalLost() {
        if (_state.value !is EventJoinUiState.Sensing) return
        scanPhase = applySignalLost(scanPhase)
        _state.value = EventJoinUiState.Sensing(scanPhase)
    }

    override fun resumeSensing() {
        if (_state.value !is EventJoinUiState.Sensing) return
        scanPhase = applyResumeSensing(scanPhase)
        _state.value = EventJoinUiState.Sensing(scanPhase)
    }

    /**
     * Mirrors iOS's `SensingCoordinator.leaveEvent()` (`engine.leaveEvent()`
     * + resetting `joinedEventCode`), adapted for this class's richer local
     * state. iOS's version is minimal because `joinedEventCode: String?` is
     * its only local session bookkeeping; this class additionally carries
     * [scanPhase] and [accounting], so a bare `engine.leaveEvent()` call
     * alone would leave both stale (still reporting a [ScanPhase]/[state] as
     * if a session were active). [applyStopSensing] is the same "any phase ->
     * IDLE" shared-authorized transition [dispose] already uses — reusing it
     * here (rather than deciding a new transition) keeps the resulting phase
     * decision inside the existing shared-owned contract instead of inventing
     * a second one.
     */
    override fun leaveEvent() {
        engine.leaveEvent()
        scanPhase = applyStopSensing()
        accounting.reset()
        _state.value = EventJoinUiState.Idle
    }

    override fun openAppSettings() = engine.openAppSettings()

    override fun requestBluetoothPermission(onComplete: () -> Unit) {
        engine.requestPermissions { _ -> onComplete() }
    }

    fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean =
        engine.onRequestPermissionsResult(requestCode, permissions, grantResults)

    /** Explicit stop/reset at Activity teardown — mirrors iOS's `endSensing(stopEngine: true)`. */
    fun dispose() {
        scanPhase = applyStopSensing()
        engine.dispose()
    }

    private companion object {
        /** Mirrors iOS's `SensingCoordinator.handleDetection`'s `"Unknown Event"` fallback. */
        const val UNKNOWN_EVENT_CODE = "Unknown Event"
    }
}

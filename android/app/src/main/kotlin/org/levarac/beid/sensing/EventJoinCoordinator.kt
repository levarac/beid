package org.levarac.beid.sensing

import android.app.Activity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.levarac.barnard.BarnardEvent
import org.levarac.barnard.BarnardPermissionResult
import org.levarac.parallax.discovery.NearbyEventCandidates

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
 * Wraps Barnard through [BarnardEventJoinEngine] (permission request →
 * `joinEvent` → `startAuto`)
 * behind the native [ScanPhase] state machine driven by
 * `org.levarac.beid.shared.sensing` (beid#116/#120) — the Android
 * counterpart of iOS's `SensingCoordinator`, scoped to this app's one
 * screen. This adapter holds no threshold or transition-graph logic of its
 * own; every phase decision is a single call into [applyPhaseDecision] or
 * one of the explicit-action functions in `ScanPhase.kt`.
 */
class EventJoinCoordinator internal constructor(
    private val engine: EventJoinEngine,
    nowEpochMillis: () -> Long,
    coroutineScope: CoroutineScope,
) : EventJoinSession {
    constructor(activity: Activity) : this(
        engine = BarnardEventJoinEngine(activity),
        nowEpochMillis = System::currentTimeMillis,
        coroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    )

    private val accounting = ScanDeviceAccounting()
    private val nearbyDiscovery = NearbyEventDiscoverySession(
        nowEpochMillis = nowEpochMillis,
        coroutineScope = coroutineScope,
    )

    private val _state = MutableStateFlow<EventJoinUiState>(EventJoinUiState.Idle)
    override val state: StateFlow<EventJoinUiState> = _state.asStateFlow()
    val nearbyEventCandidates: StateFlow<NearbyEventCandidates> = nearbyDiscovery.candidates

    /** Source of truth for the current [ScanPhase] — mirrors [_state]'s payload once `Sensing` is reached. */
    private var scanPhase: ScanPhase = ScanPhase.Idle
    private var discoveryOnlyScanOwned = false
    private var disposed = false

    init {
        engine.onEvent = ::handleBarnardEvent
    }

    override fun joinEvent(code: String) {
        if (disposed) return
        _state.value = EventJoinUiState.RequestingPermission
        engine.requestPermissions { result ->
            if (disposed) return@requestPermissions
            if (result is BarnardPermissionResult.Granted && result.status.canScan && result.status.canAdvertise) {
                engine.joinEvent(code)
                discoveryOnlyScanOwned = false
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
        if (disposed) return
        when (event) {
            is BarnardEvent.EventInfoHint -> {
                val hint = event.hint
                nearbyDiscovery.recordHint(
                    peripheralId = hint.peripheralId,
                    eventDisplayName = hint.eventInfo.eventDisplayName,
                    eventCodeHash = hint.eventInfo.eventCodeHash,
                    census = hint.eventInfo.census,
                    additionalNamesOmitted = hint.additionalNamesOmitted,
                    additionalEventsOmitted = hint.additionalEventsOmitted,
                )
            }
            is BarnardEvent.Detection -> {
                val detection = event.detection
                handleDetection(
                    enin = detection.enin,
                    rpid = detection.rpid,
                    detectedDisplayId = detection.detectedDisplayId,
                )
            }
            else -> Unit
        }
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
        if (disposed) return
        engine.leaveEvent()
        discoveryOnlyScanOwned = false
        nearbyDiscovery.reset()
        scanPhase = applyStopSensing()
        accounting.reset()
        _state.value = EventJoinUiState.Idle
    }

    override fun openAppSettings() = engine.openAppSettings()

    override fun requestBluetoothPermission(onComplete: () -> Unit) {
        if (disposed) return
        engine.requestPermissions { result ->
            if (disposed) return@requestPermissions
            if (result is BarnardPermissionResult.Granted && result.status.canScan) {
                startNearbyEventDiscoveryIfIdle()
            }
            onComplete()
        }
    }

    private fun startNearbyEventDiscoveryIfIdle() {
        if (disposed || scanPhase != ScanPhase.Idle || discoveryOnlyScanOwned) return
        val engineState = engine.getState()
        if (engineState.isScanning || engineState.isAdvertising) return
        engine.startScan()
        discoveryOnlyScanOwned = true
    }

    fun stopNearbyEventDiscovery() {
        val isAdvertising = !disposed && engine.getState().isAdvertising
        val shouldStopScan = discoveryOnlyScanOwned &&
            scanPhase == ScanPhase.Idle &&
            !disposed &&
            !isAdvertising
        discoveryOnlyScanOwned = false
        nearbyDiscovery.reset()
        if (shouldStopScan) engine.stopScan()
    }

    fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean =
        !disposed && engine.onRequestPermissionsResult(requestCode, permissions, grantResults)

    /** Explicit stop/reset at Activity teardown — mirrors iOS's `endSensing(stopEngine: true)`. */
    fun dispose() {
        if (disposed) return
        disposed = true
        discoveryOnlyScanOwned = false
        nearbyDiscovery.dispose()
        scanPhase = applyStopSensing()
        engine.onEvent = null
        engine.dispose()
    }

    private companion object {
        /** Mirrors iOS's `SensingCoordinator.handleDetection`'s `"Unknown Event"` fallback. */
        const val UNKNOWN_EVENT_CODE = "Unknown Event"
    }
}

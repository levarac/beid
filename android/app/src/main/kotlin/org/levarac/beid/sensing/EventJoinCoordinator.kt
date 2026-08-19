package org.levarac.beid.sensing

import android.app.Activity
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.levarac.barnard.BarnardEngine
import org.levarac.barnard.BarnardPermissionResult

/**
 * UI-facing state for [EventJoinCoordinator]. Mirrors the shape of iOS's
 * `SensingCoordinator` phases (`ios/Beid/Sensing/SensingCoordinator.swift`)
 * but scoped to just this scaffold's one screen: request permission, then
 * join the event and start sensing.
 */
sealed class EventJoinUiState {
    data object Idle : EventJoinUiState()
    data object RequestingPermission : EventJoinUiState()
    data object Sensing : EventJoinUiState()
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
 * Thin wrapper around [BarnardEngine] proving the Barnard SDK call
 * compiles and runs end to end (permission request → `joinEvent` →
 * `startAuto`). This is intentionally not a full `SensingCoordinator` port —
 * see android/README.md for scaffold scope.
 */
class EventJoinCoordinator(private val activity: Activity) : EventJoinSession {
    private val engine = BarnardEngine(activity.applicationContext).apply {
        setActivity(activity)
    }

    private val _state = MutableStateFlow<EventJoinUiState>(EventJoinUiState.Idle)
    override val state: StateFlow<EventJoinUiState> = _state.asStateFlow()

    override fun joinEvent(code: String) {
        _state.value = EventJoinUiState.RequestingPermission
        engine.requestPermissions { result ->
            if (result is BarnardPermissionResult.Granted && result.status.canScan && result.status.canAdvertise) {
                engine.joinEvent(code)
                engine.startAuto()
                _state.value = EventJoinUiState.Sensing
            } else {
                _state.value = mapPermissionResultToState(result)
            }
        }
    }

    override fun openAppSettings() = engine.openAppSettings()

    fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean =
        engine.onRequestPermissionsResult(requestCode, permissions, grantResults)

    fun dispose() = engine.dispose()
}

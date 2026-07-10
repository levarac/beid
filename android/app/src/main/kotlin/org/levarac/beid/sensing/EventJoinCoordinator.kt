package org.levarac.beid.sensing

import android.app.Activity
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import network.greeting.barnard.BarnardEngine
import network.greeting.barnard.BarnardPermissionResult

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
}

/**
 * Thin wrapper around [BarnardEngine] proving the vendored Barnard SDK call
 * compiles and runs end to end (permission request → `joinEvent` →
 * `startAuto`). This is intentionally not a full `SensingCoordinator` port —
 * see android/README.md for scaffold scope.
 */
class EventJoinCoordinator(private val activity: Activity) {
    private val engine = BarnardEngine(activity.applicationContext).apply {
        setActivity(activity)
    }

    private val _state = MutableStateFlow<EventJoinUiState>(EventJoinUiState.Idle)
    val state: StateFlow<EventJoinUiState> = _state.asStateFlow()

    fun joinEvent(code: String) {
        _state.value = EventJoinUiState.RequestingPermission
        engine.requestPermissions { result ->
            when (result) {
                is BarnardPermissionResult.Granted -> {
                    if (result.status.canScan && result.status.canAdvertise) {
                        engine.joinEvent(code)
                        engine.startAuto()
                        _state.value = EventJoinUiState.Sensing
                    } else {
                        _state.value = EventJoinUiState.PermissionDenied
                    }
                }
                is BarnardPermissionResult.Failed -> {
                    _state.value = EventJoinUiState.PermissionDenied
                }
            }
        }
    }

    fun openAppSettings() = engine.openAppSettings()

    fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean =
        engine.onRequestPermissionsResult(requestCode, permissions, grantResults)

    fun dispose() = engine.dispose()
}

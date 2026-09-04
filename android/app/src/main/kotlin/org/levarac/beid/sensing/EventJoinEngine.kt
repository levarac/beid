package org.levarac.beid.sensing

import android.app.Activity
import org.levarac.barnard.BarnardDebugEvent
import org.levarac.barnard.BarnardEngine
import org.levarac.barnard.BarnardEvent
import org.levarac.barnard.BarnardPermissionResult

internal data class EventJoinEngineState(
    val isScanning: Boolean,
    val isAdvertising: Boolean,
)

/**
 * The Android-effect boundary used by [EventJoinCoordinator].
 *
 * Production forwards to Barnard while plain JVM tests inject a fake. No
 * Barnard protocol decision is reproduced on this side of the boundary.
 */
internal interface EventJoinEngine {
    var onEvent: ((BarnardEvent) -> Unit)?

    fun requestPermissions(callback: (BarnardPermissionResult) -> Unit)

    fun startScan()

    fun stopScan()

    fun joinEvent(code: String)

    fun startAuto()

    fun leaveEvent()

    fun getState(): EventJoinEngineState

    fun getCurrentEventCode(): String?

    fun openAppSettings()

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean

    fun dispose()
}

/** Activity-bound production forwarding facade for the native Barnard SDK. */
internal class BarnardEventJoinEngine(activity: Activity) : EventJoinEngine {
    private val engine = BarnardEngine(activity.applicationContext).apply {
        setActivity(activity)
    }

    override var onEvent: ((BarnardEvent) -> Unit)?
        get() = engine.onEvent
        set(value) {
            engine.onEvent = value
        }

    internal var onDebugEvent: ((BarnardDebugEvent) -> Unit)?
        get() = engine.onDebugEvent
        set(value) {
            engine.onDebugEvent = value
        }

    override fun requestPermissions(callback: (BarnardPermissionResult) -> Unit) {
        engine.requestPermissions(callback)
    }

    override fun startScan() {
        engine.startScan()
    }

    override fun stopScan() {
        engine.stopScan()
    }

    override fun joinEvent(code: String) {
        engine.joinEvent(code)
    }

    override fun startAuto() {
        engine.startAuto()
    }

    override fun leaveEvent() {
        engine.leaveEvent()
    }

    override fun getState(): EventJoinEngineState = engine.getState().let { state ->
        EventJoinEngineState(
            isScanning = state.isScanning,
            isAdvertising = state.isAdvertising,
        )
    }

    override fun getCurrentEventCode(): String? = engine.getCurrentEventCode()

    override fun openAppSettings() {
        engine.openAppSettings()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean = engine.onRequestPermissionsResult(requestCode, permissions, grantResults)

    override fun dispose() {
        engine.dispose()
    }
}

package org.levarac.beid.sensing

import android.app.Activity
import org.levarac.barnard.BarnardDebugEvent
import org.levarac.barnard.BarnardEngine
import org.levarac.barnard.BarnardEvent
import org.levarac.barnard.BarnardPermissionResult
import org.levarac.barnard.BarnardRelayVerifier
import org.levarac.parallax.discovery.RegistryVerifiedJoinContext

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

    /**
     * Joins the verified event and starts automatic operation, as one act
     * (beid#374).
     *
     * There is deliberately no `joinEvent(String)` and no argumentless
     * `startAuto()` on this interface any more. Barnard's string join API
     * still exists and is still what gets called, but the conversion from a
     * capability to that string happens inside the production adapter below,
     * where it cannot be reached with a string that did not come from a
     * registry-verified context. A coordinator holding only an event code has
     * no method to call, and that is a compile error rather than a review
     * comment.
     *
     * The two were merged rather than kept as an ordered pair because a pair
     * can be half-called: a host that joined and then returned early would
     * leave barnard joined to an event this app is not sensing for.
     */
    fun joinAndStart(context: RegistryVerifiedJoinContext)

    fun leaveEvent()

    /**
     * Enables barnard's spec 134 participant relay, or disables it when
     * [verifier] is null. The relay itself lives in barnard; this host only
     * says whether an envelope may be re-broadcast and when the feature is on.
     */
    fun configureParticipantRelay(verifier: BarnardRelayVerifier?)

    /**
     * Runs the relay's 30-second lease decisions. barnard drives this on its
     * own timer as well; a host calling it keeps the cadence tied to this
     * app's own liveness rather than only to the SDK's.
     */
    fun advanceParticipantRelay()

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

    /**
     * The only place in this app where an event code reaches barnard's string
     * join API. The string is not chosen here — it is
     * [RegistryVerifiedJoinContext.joinCode], fixed by the shared issuer when
     * the capability was granted, so this adapter cannot pair a verified event
     * with any other text.
     */
    override fun joinAndStart(context: RegistryVerifiedJoinContext) {
        engine.joinEvent(context.joinCode)
        engine.startAuto()
    }

    override fun leaveEvent() {
        engine.leaveEvent()
    }

    override fun configureParticipantRelay(verifier: BarnardRelayVerifier?) {
        engine.configureParticipantRelay(verifier)
    }

    override fun advanceParticipantRelay() {
        engine.advanceParticipantRelay()
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

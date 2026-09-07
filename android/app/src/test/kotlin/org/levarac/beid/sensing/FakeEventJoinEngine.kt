package org.levarac.beid.sensing

import org.levarac.barnard.BarnardDetectionEvent
import org.levarac.barnard.BarnardB005EnvelopeV2Receipt
import org.levarac.barnard.BarnardEvent
import org.levarac.barnard.BarnardEventInfoEnvelopeV2Event
import org.levarac.barnard.BarnardEventInfo
import org.levarac.barnard.BarnardEventInfoHintEvent
import org.levarac.barnard.BarnardPermissionResult
import org.levarac.barnard.BarnardRelayVerifier
import org.levarac.barnard.BarnardPermissionStatus

/**
 * Shared [EventJoinEngine] test double — promoted out of
 * `EventJoinCoordinatorDiscoveryAdapterTest` (its original, file-private
 * home) so [EventJoinCoordinatorSelfProofTest]/[EventJoinCoordinatorBindingTest]
 * can reuse it instead of duplicating the fake-engine plumbing, and
 * extended with [emitDetection] (detection events; the discovery-adapter
 * test only ever needed [emitHint]).
 */
internal class FakeEventJoinEngine(
    private var permissionResult: BarnardPermissionResult? = GRANTED,
) : EventJoinEngine {
    override var onEvent: ((BarnardEvent) -> Unit)? = null
    var engineState = EventJoinEngineState(isScanning = false, isAdvertising = false)
    var startScanCalls = 0
    var stopScanCalls = 0
    var startAutoCalls = 0
    var disposeCalls = 0
    private var permissionCallback: ((BarnardPermissionResult) -> Unit)? = null
    private var eventCode: String? = null

    override fun requestPermissions(callback: (BarnardPermissionResult) -> Unit) {
        permissionCallback = callback
        permissionResult?.let(::completePermissionRequest)
    }

    fun completePermissionRequest(result: BarnardPermissionResult) {
        permissionCallback?.also { permissionCallback = null }?.invoke(result)
    }

    override fun startScan() {
        startScanCalls += 1
        engineState = engineState.copy(isScanning = true)
    }

    override fun stopScan() {
        stopScanCalls += 1
        engineState = engineState.copy(isScanning = false)
    }

    override fun joinEvent(code: String) {
        eventCode = code
    }

    override fun startAuto() {
        startAutoCalls += 1
        engineState = EventJoinEngineState(isScanning = true, isAdvertising = true)
    }

    var configuredRelayVerifier: BarnardRelayVerifier? = null
        private set
    var relayConfigureCalls: Int = 0
        private set
    var advanceRelayCalls: Int = 0
        private set

    override fun configureParticipantRelay(verifier: BarnardRelayVerifier?) {
        relayConfigureCalls += 1
        configuredRelayVerifier = verifier
    }

    override fun advanceParticipantRelay() {
        advanceRelayCalls += 1
    }

    override fun leaveEvent() {
        eventCode = null
        // Deliberately mirrors Barnard 0.4: leaveEvent stops neither transport.
    }

    override fun getState(): EventJoinEngineState = engineState

    override fun getCurrentEventCode(): String? = eventCode

    override fun openAppSettings() = Unit

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean = false

    override fun dispose() {
        disposeCalls += 1
        engineState = EventJoinEngineState(isScanning = false, isAdvertising = false)
        onEvent = null
    }

    /**
     * Emits a B005 v2 envelope whose receipt is `Unverified`.
     *
     * Only this half of the two-case receipt can be built in a test: the
     * `RadioSelfVerified` case wraps `BarnardB005VerifiedEnvelope`, whose
     * constructor is private and whose only factory is barnard-internal, so a
     * verified receipt can be produced by `BarnardB005EnvelopeV2.verify`
     * alone. The verified path is covered at the session seam instead.
     */
    fun emitUnverifiedEnvelopeV2(peripheralId: String, container: ByteArray = ByteArray(4)) {
        onEvent?.invoke(
            BarnardEvent.EventInfoEnvelopeV2(
                BarnardEventInfoEnvelopeV2Event(
                    peripheralId = peripheralId,
                    receipt = BarnardB005EnvelopeV2Receipt.Unverified,
                    rawContainer = container,
                ),
            ),
        )
    }

    fun emitHint(
        peripheralId: String,
        displayName: String,
        hash: ByteArray,
        census: ByteArray? = null,
        additionalNamesOmitted: Boolean = false,
        additionalEventsOmitted: Boolean = false,
    ) {
        onEvent?.invoke(
            BarnardEvent.EventInfoHint(
                BarnardEventInfoHintEvent(
                    peripheralId = peripheralId,
                    eventInfo = BarnardEventInfo(displayName, hash, census),
                    additionalNamesOmitted = additionalNamesOmitted,
                    additionalEventsOmitted = additionalEventsOmitted,
                ),
            ),
        )
    }

    fun emitDetection(
        enin: Long,
        rpid: String,
        detectedDisplayId: String?,
        reporterRpid: String = "00",
        timestampMs: Long = 0,
        rssi: Int = -50,
        formatVersion: Int = 1,
        debugLocalName: String? = null,
    ) {
        onEvent?.invoke(
            BarnardEvent.Detection(
                BarnardDetectionEvent(
                    timestampMs = timestampMs,
                    rssi = rssi,
                    formatVersion = formatVersion,
                    rpid = rpid,
                    reporterRpid = reporterRpid,
                    detectedDisplayId = detectedDisplayId,
                    enin = enin,
                    debugLocalName = debugLocalName,
                ),
            ),
        )
    }

    companion object {
        val GRANTED = BarnardPermissionResult.Granted(
            BarnardPermissionStatus(
                platform = "android",
                permissions = emptyMap(),
                requiredPermissions = emptyList(),
                missingPermissions = emptyList(),
                requestablePermissions = emptyList(),
                blockedPermissions = emptyList(),
                canScan = true,
                canAdvertise = true,
            ),
        )
    }
}

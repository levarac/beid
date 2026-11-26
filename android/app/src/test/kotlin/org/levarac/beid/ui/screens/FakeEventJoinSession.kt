package org.levarac.beid.ui.screens

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.levarac.beid.sensing.EventJoinSession
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.BluetoothPermissionState
import org.levarac.beid.sensing.NearbyEventCard
import org.levarac.beid.sensing.SensingRadarPeerSignal
import org.levarac.beid.shared.event.NearbyEventSearchOutcome

/** Shared test double for [EventJoinSession] — no real `Activity`/`BarnardEngine` involved. */
internal class FakeEventJoinSession(
    initial: EventJoinUiState = EventJoinUiState.Idle,
    nearbyEventCards: List<NearbyEventCard> = emptyList(),
    nearbyEventsOmitted: Boolean = false,
    initialBluetoothPermissionState: BluetoothPermissionState = BluetoothPermissionState.Granted,
) : EventJoinSession {
    private val mutableState = MutableStateFlow(initial)
    override val state: StateFlow<EventJoinUiState> = mutableState.asStateFlow()
    private val mutableNearbyEventCards = MutableStateFlow(nearbyEventCards)
    override val nearbyEventCards: StateFlow<List<NearbyEventCard>> = mutableNearbyEventCards.asStateFlow()
    private val mutableSearchOutcome = MutableStateFlow(NearbyEventSearchOutcome.SEARCHING)
    override val nearbyEventSearchOutcome: StateFlow<NearbyEventSearchOutcome> =
        mutableSearchOutcome.asStateFlow()
    private val mutableNearbyEventsOmitted = MutableStateFlow(nearbyEventsOmitted)
    override val nearbyEventsOmitted: StateFlow<Boolean> = mutableNearbyEventsOmitted.asStateFlow()
    private val mutableRadarPeers = MutableStateFlow<List<SensingRadarPeerSignal>>(emptyList())
    override val radarPeers: StateFlow<List<SensingRadarPeerSignal>> = mutableRadarPeers.asStateFlow()

    /** Settable so a test can change the runtime answer the next refresh reads. */
    override var bluetoothPermissionState: BluetoothPermissionState = initialBluetoothPermissionState

    /** Every radio state the host forwarded, in order. */
    val bluetoothRadioChanges = mutableListOf<Boolean>()

    override fun refreshBluetoothPermissionState(): BluetoothPermissionState = bluetoothPermissionState

    override fun onBluetoothRadioChanged(isOn: Boolean) {
        bluetoothRadioChanges += isOn
    }

    var joinedCode: String? = null
        private set
    var joinedNearbyEventCodeHashHex: String? = null
        private set
    var openedAppSettings: Boolean = false
        private set
    var signalLostSimulated: Boolean = false
        private set
    var sensingResumed: Boolean = false
        private set
    var permissionRequested: Boolean = false
        private set
    var nearbyEventDiscoveryStartCalls: Int = 0
        private set
    var leaveEventCallCount: Int = 0
        private set
    override var recordingCeremonyShown: Boolean = false
        private set

    override fun joinEvent(code: String) {
        joinedCode = code
    }

    override fun joinNearbyEvent(eventCodeHashHex: String) {
        joinedNearbyEventCodeHashHex = eventCodeHashHex
    }

    override fun openAppSettings() {
        openedAppSettings = true
    }

    override fun requestBluetoothPermission(onResult: (BluetoothPermissionState) -> Unit) {
        permissionRequested = true
        onResult(bluetoothPermissionState)
    }

    override fun startNearbyEventDiscovery() {
        nearbyEventDiscoveryStartCalls += 1
    }

    var nearbyEventDiscoveryStopCalls: Int = 0
        private set

    override fun stopNearbyEventDiscovery() {
        nearbyEventDiscoveryStopCalls += 1
    }

    override fun simulateSignalLost() {
        signalLostSimulated = true
    }

    override fun resumeSensing() {
        sensingResumed = true
    }

    override fun leaveEvent() {
        leaveEventCallCount += 1
    }

    override fun markRecordingCeremonyShown() {
        recordingCeremonyShown = true
    }

    fun emit(next: EventJoinUiState) {
        mutableState.value = next
    }

    private val radarLastHeardAtMillis = HashMap<String, Long>()

    override fun radarPeerLastHeardAtMillis(displayId: String): Long? = radarLastHeardAtMillis[displayId]

    /** Publishes [peers], each last heard at [heardAtMillis] (wall clock, as Barnard stamps). */
    fun emitRadarPeers(peers: List<SensingRadarPeerSignal>, heardAtMillis: Long = System.currentTimeMillis()) {
        peers.forEach { hearRadarPeer(it.displayId, heardAtMillis) }
        mutableRadarPeers.value = peers
    }

    /** An RSSI-only refresh: moves lastHeard without publishing, as the coordinator does. */
    fun hearRadarPeer(displayId: String, atMillis: Long) {
        radarLastHeardAtMillis[displayId] = maxOf(radarLastHeardAtMillis[displayId] ?: atMillis, atMillis)
    }

    fun emitNearbyEventCards(cards: List<NearbyEventCard>) {
        mutableNearbyEventCards.value = cards
    }

    fun emitSearchOutcome(outcome: NearbyEventSearchOutcome) {
        mutableSearchOutcome.value = outcome
    }

    fun clearJoinedNearbyEvent() {
        joinedNearbyEventCodeHashHex = null
    }
}

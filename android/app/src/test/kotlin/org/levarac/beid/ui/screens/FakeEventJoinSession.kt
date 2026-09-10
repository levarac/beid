package org.levarac.beid.ui.screens

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.levarac.beid.sensing.EventJoinSession
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.NearbyEventCard
import org.levarac.beid.shared.event.NearbyEventSearchOutcome

/** Shared test double for [EventJoinSession] — no real `Activity`/`BarnardEngine` involved. */
internal class FakeEventJoinSession(
    initial: EventJoinUiState = EventJoinUiState.Idle,
    nearbyEventCards: List<NearbyEventCard> = emptyList(),
) : EventJoinSession {
    private val mutableState = MutableStateFlow(initial)
    override val state: StateFlow<EventJoinUiState> = mutableState.asStateFlow()
    private val mutableNearbyEventCards = MutableStateFlow(nearbyEventCards)
    override val nearbyEventCards: StateFlow<List<NearbyEventCard>> = mutableNearbyEventCards.asStateFlow()
    private val mutableSearchOutcome = MutableStateFlow(NearbyEventSearchOutcome.SEARCHING)
    override val nearbyEventSearchOutcome: StateFlow<NearbyEventSearchOutcome> =
        mutableSearchOutcome.asStateFlow()

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

    override fun requestBluetoothPermission(onComplete: () -> Unit) {
        permissionRequested = true
        onComplete()
    }

    override fun startNearbyEventDiscovery() {
        nearbyEventDiscoveryStartCalls += 1
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

package org.levarac.beid.navigation

import android.os.SystemClock
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.levarac.beid.sensing.EventJoinSession
import org.levarac.beid.sensing.EventJoinUiState

/** What Now renders from the standby gate. */
data class NowStandbyPresentation(
    /** Now is the enabled, empty-discovery surface and its wait is running. */
    val listening: Boolean = false,
    /** Whole seconds of the uninterrupted wait, for the listening strip's `m:ss`. */
    val elapsedSeconds: Long = 0L,
    /** The 30-second event-code entry (iOS `home.enter-code`). */
    val offersCodeEntry: Boolean = false,
)

/**
 * The Now tab's standby gate — the Android port of iOS
 * `AppCoordinator.updateHomeStandby(isVisible:isSceneActive:)` (PR #795).
 *
 * Discovery runs only while the gate is open, and the gate is open only while
 * all of these hold:
 * - the Now tab is selected ([onTabSelected]);
 * - the Home back-stack entry is resumed ([onRootResumedChanged]). Navigation
 *   bounds that entry's lifecycle by the Activity's, so this one input covers
 *   both iOS's `isSceneActive` (app in the foreground) and its
 *   `!accountSheetPresented && !homeEventCodeSheetPresented` (Account and
 *   event-code entry are routes pushed over Home on Android);
 * - Bluetooth is not off ([onBluetoothOffChanged]);
 * - the session is at rest: not sensing and no join in flight.
 *
 * Leaving any of them closes the gate and discards the 30-second wait. Closing
 * the gate stops discovery only while the session is at rest, as iOS does
 * with `if isIdle { stopNearbyEventDiscovery() }`: a JOIN tap moves the
 * session into permission and registry checks with its candidate still
 * needed, and a joined session owns its own scan.
 *
 * A gate closed during such a join still owes that stop ([stopOwed]). If the
 * join is refused, the session comes back to rest and nothing else would
 * ever stop the scan (`EventJoinCoordinator.refuseJoin` leaves discovery
 * running for Now), so the gate stops it then, provided it is still closed;
 * if it has reopened by then, the open gate takes discovery back instead. A
 * join that reaches sensing cancels the debt: the joined session owns its
 * scan from then on (iOS `joinAndStart` clears `discoveryOnlyScanOwned`).
 *
 * The 30-second wait counts only joinable candidates, cards whose JOIN Now
 * enables (`eventIdHex != null`), as iOS release/1.1.0 does: a card shown with
 * JOIN disabled leaves nothing to tap, so it does not hold back the entry.
 *
 * This gate is the one owner of whether standby discovery should run. The
 * session only decides whether it can: a start requested while the radio is
 * off is deferred until the radio returns, and [EventJoinSession.stopNearbyEventDiscovery]
 * withdraws it (`EventJoinCoordinator.onBluetoothRadioChanged`), so the radio
 * never restarts discovery behind a closed gate.
 *
 * [uptimeMillis] is injected so tests measure the wait on virtual time.
 */
class HomeStandbyViewModel(
    private val session: EventJoinSession,
    private val uptimeMillis: () -> Long = SystemClock::uptimeMillis,
) : ViewModel() {
    private var selectedTab = HomeTab.Now
    private var rootResumed = false
    private var bluetoothOff = false
    private var standby = HomeStandbyState()
    private var tickJob: Job? = null

    /** Whether this gate currently holds discovery open (iOS `homeStandbyDiscoveryActive`). */
    var discoveryActive: Boolean = false
        private set

    /**
     * The gate closed while a join was in flight and left its discovery
     * running for that join; the stop is made once the session is back at
     * rest behind a still-closed gate.
     */
    private var stopOwed = false

    private val _presentation = MutableStateFlow(NowStandbyPresentation())
    val presentation: StateFlow<NowStandbyPresentation> = _presentation.asStateFlow()

    init {
        viewModelScope.launch { session.state.collect { refresh() } }
        viewModelScope.launch { session.nearbyEventCards.collect { refresh() } }
    }

    fun onTabSelected(tab: HomeTab) {
        selectedTab = tab
        refresh()
    }

    fun onRootResumedChanged(resumed: Boolean) {
        rootResumed = resumed
        refresh()
    }

    fun onBluetoothOffChanged(off: Boolean) {
        bluetoothOff = off
        refresh()
    }

    private fun refresh() {
        val sessionState = session.state.value
        val atRest = sessionState.isAtRest()
        val isEnabled = selectedTab == HomeTab.Now && rootResumed && !bluetoothOff && atRest
        if (sessionState is EventJoinUiState.Sensing) stopOwed = false
        if (isEnabled && !discoveryActive) {
            discoveryActive = true
            stopOwed = false
            session.startNearbyEventDiscovery()
        } else if (!isEnabled && discoveryActive) {
            discoveryActive = false
            if (atRest) {
                session.stopNearbyEventDiscovery()
            } else if (sessionState !is EventJoinUiState.Sensing) {
                stopOwed = true
            }
        } else if (!isEnabled && stopOwed && atRest) {
            stopOwed = false
            session.stopNearbyEventDiscovery()
        }
        val now = uptimeMillis()
        standby = standby.update(
            isEnabled = isEnabled,
            hasJoinableCandidates = session.nearbyEventCards.value.any { it.eventIdHex != null },
            nowMillis = now,
        )
        publish(now)
        if (standby.listeningStartedAtMillis != null) startTicking() else stopTicking()
    }

    private fun publish(now: Long) {
        _presentation.value = NowStandbyPresentation(
            listening = standby.listeningStartedAtMillis != null,
            elapsedSeconds = standby.elapsedMillis(now) / 1_000L,
            offersCodeEntry = standby.offersCodeEntry(now),
        )
    }

    /**
     * Republishes on every whole second of the wait, so the strip's timer
     * advances and the entry appears exactly at 30 s rather than up to one
     * tick late.
     */
    private fun startTicking() {
        if (tickJob?.isActive == true) return
        tickJob = viewModelScope.launch {
            while (true) {
                val elapsed = standby.elapsedMillis(uptimeMillis())
                delay(TICK_MILLIS - elapsed % TICK_MILLIS)
                publish(uptimeMillis())
            }
        }
    }

    private fun stopTicking() {
        tickJob?.cancel()
        tickJob = null
    }

    /**
     * A stop owed at rest is made here too: the session may have come back to
     * rest before this gate's collector heard it, and nothing collects after
     * clearing. A join still in flight keeps its candidate, as in [refresh].
     */
    override fun onCleared() {
        stopTicking()
        if ((discoveryActive || stopOwed) && session.state.value.isAtRest()) session.stopNearbyEventDiscovery()
        discoveryActive = false
        stopOwed = false
    }

    class Factory(
        private val session: EventJoinSession,
        private val uptimeMillis: () -> Long = SystemClock::uptimeMillis,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            HomeStandbyViewModel(session, uptimeMillis) as T
    }

    private companion object {
        const val TICK_MILLIS = 1_000L
    }
}

/**
 * Not sensing and no join in flight — the Android counterpart of iOS's
 * `phase == .idle`. A refused or blocked join returns here.
 */
internal fun EventJoinUiState.isAtRest(): Boolean = when (this) {
    EventJoinUiState.Idle,
    EventJoinUiState.PermissionDenied,
    is EventJoinUiState.OwnerKeyUnavailable,
    is EventJoinUiState.JoinFailed,
    -> true
    EventJoinUiState.RequestingPermission,
    EventJoinUiState.VerifyingRegistry,
    is EventJoinUiState.Sensing,
    -> false
}

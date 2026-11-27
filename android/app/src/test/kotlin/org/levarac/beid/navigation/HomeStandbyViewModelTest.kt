package org.levarac.beid.navigation

import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.NearbyEventCard
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.shared.event.EventJoinFailureReason
import org.levarac.beid.ui.screens.FakeEventJoinSession

/**
 * The Now standby gate and its 30-second code-entry wait on virtual time —
 * the Android counterpart of iOS `HomeStandbyLifecycleTests` (PR #795).
 * The uptime clock is the test scheduler's clock, so `advanceTimeBy` moves
 * both the ticker and the time the wait is measured against.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class HomeStandbyViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    private val card = NearbyEventCard("Nearby", eventIdHex = "ab".repeat(16), eventCodeHashHex = "cd".repeat(8))

    /** No registry-verified event ID, so Now renders its JOIN disabled. */
    private val unjoinableCard = NearbyEventCard("Unnamed beacon nearby", eventIdHex = null, eventCodeHashHex = "ef".repeat(8))

    @BeforeTest fun setUp() = Dispatchers.setMain(dispatcher)
    @AfterTest fun tearDown() = Dispatchers.resetMain()

    /**
     * Runs [body] against a ViewModel owned by a [ViewModelStore] that is
     * cleared before `runTest` drains the scheduler: the strip's ticker runs
     * for as long as Now listens, so a ViewModel left alive would keep
     * virtual time from ever going idle.
     */
    private fun standbyTest(
        session: FakeEventJoinSession = FakeEventJoinSession(),
        body: suspend TestScope.(HomeStandbyViewModel, FakeEventJoinSession) -> Unit,
    ) = runTest(dispatcher) {
        val store = ViewModelStore()
        val viewModel = ViewModelProvider.create(
            store,
            HomeStandbyViewModel.Factory(session) { testScheduler.currentTime },
        )[HomeStandbyViewModel::class.java]
        runCurrent()
        try {
            body(viewModel, session)
        } finally {
            store.clear()
        }
    }

    /** Now visible on a resumed Home entry with Bluetooth on: every condition the gate needs. */
    private fun TestScope.enable(viewModel: HomeStandbyViewModel) {
        viewModel.onBluetoothOffChanged(false)
        viewModel.onTabSelected(HomeTab.Now)
        viewModel.onRootResumedChanged(true)
        runCurrent()
    }

    @Test
    fun visibleIdleNowStartsOnlyDiscoveryOnceAndLeavingStopsIt() = standbyTest(FakeEventJoinSession()) { viewModel, session ->
        assertEquals(0, session.nearbyEventDiscoveryStartCalls, "Nothing starts before Now is resumed")
        enable(viewModel)
        viewModel.onRootResumedChanged(true)
        runCurrent()
        assertEquals(1, session.nearbyEventDiscoveryStartCalls)
        assertEquals(null, session.joinedNearbyEventCodeHashHex)
        assertTrue(viewModel.presentation.value.listening)

        viewModel.onRootResumedChanged(false)
        runCurrent()
        assertEquals(1, session.nearbyEventDiscoveryStopCalls)
        assertFalse(viewModel.presentation.value.listening)
    }

    @Test
    fun backgroundAccountAndTabSwitchingPauseAndRestartDiscovery() = standbyTest(FakeEventJoinSession()) { viewModel, session ->
        enable(viewModel)
        // Background, or Account / event-code entry pushed over Home: the
        // Home entry is no longer resumed.
        viewModel.onRootResumedChanged(false)
        runCurrent()
        assertEquals(1, session.nearbyEventDiscoveryStopCalls)
        viewModel.onRootResumedChanged(true)
        viewModel.onTabSelected(HomeTab.Records)
        runCurrent()
        assertEquals(2, session.nearbyEventDiscoveryStopCalls)
        viewModel.onTabSelected(HomeTab.Now)
        runCurrent()
        assertEquals(3, session.nearbyEventDiscoveryStartCalls)
    }

    @Test
    fun codeEntryIsOfferedAtThirtySecondsAndNotAtTwentyNine() = standbyTest { viewModel, _ ->
        enable(viewModel)
        advanceTimeBy(29_000)
        runCurrent()
        assertEquals(29L, viewModel.presentation.value.elapsedSeconds)
        assertFalse(viewModel.presentation.value.offersCodeEntry)
        advanceTimeBy(999)
        runCurrent()
        assertFalse(viewModel.presentation.value.offersCodeEntry)
        advanceTimeBy(1)
        runCurrent()
        assertEquals(30L, viewModel.presentation.value.elapsedSeconds)
        assertTrue(viewModel.presentation.value.offersCodeEntry)
    }

    @Test
    fun switchingTabsResetsTheWait() = standbyTest { viewModel, _ ->
        enable(viewModel)
        advanceTimeBy(29_500)
        viewModel.onTabSelected(HomeTab.Records)
        runCurrent()
        viewModel.onTabSelected(HomeTab.Now)
        runCurrent()
        assertEquals(0L, viewModel.presentation.value.elapsedSeconds)
        advanceTimeBy(29_000)
        runCurrent()
        assertFalse(viewModel.presentation.value.offersCodeEntry, "The wait restarted when Now came back")
        advanceTimeBy(1_000)
        runCurrent()
        assertTrue(viewModel.presentation.value.offersCodeEntry)
    }

    @Test
    fun aCandidateAppearingWithdrawsTheEntryAndItsRemovalRestartsTheWait() = standbyTest(FakeEventJoinSession()) { viewModel, session ->
        enable(viewModel)
        advanceTimeBy(30_000)
        runCurrent()
        assertTrue(viewModel.presentation.value.offersCodeEntry)

        session.emitNearbyEventCards(listOf(card))
        runCurrent()
        assertFalse(viewModel.presentation.value.offersCodeEntry)
        assertFalse(viewModel.presentation.value.listening)
        assertEquals(0, session.nearbyEventDiscoveryStopCalls, "A candidate never stops discovery")

        session.emitNearbyEventCards(emptyList())
        runCurrent()
        advanceTimeBy(29_000)
        runCurrent()
        assertFalse(viewModel.presentation.value.offersCodeEntry)
        advanceTimeBy(1_000)
        runCurrent()
        assertTrue(viewModel.presentation.value.offersCodeEntry)
    }

    /**
     * iOS release/1.1.0 `AppCoordinator.updateHomeStandby` counts only cards
     * whose JOIN is enabled (`joinActionEventCodeHashHex != nil`, i.e. a known
     * `eventIdHex`): a card Now shows with JOIN disabled leaves the user with
     * nothing to tap, so it must not hold back ENTER EVENT CODE.
     */
    @Test
    fun anUnjoinableCardDoesNotHoldBackTheCodeEntry() = standbyTest(
        FakeEventJoinSession(nearbyEventCards = listOf(unjoinableCard)),
    ) { viewModel, _ ->
        enable(viewModel)
        assertTrue(viewModel.presentation.value.listening, "An unjoinable card leaves Now listening")
        advanceTimeBy(29_000)
        runCurrent()
        assertFalse(viewModel.presentation.value.offersCodeEntry)
        advanceTimeBy(1_000)
        runCurrent()
        assertTrue(viewModel.presentation.value.offersCodeEntry)
    }

    @Test
    fun aJoinableCardBesideAnUnjoinableOneStillWithholdsTheCodeEntry() = standbyTest(
        FakeEventJoinSession(nearbyEventCards = listOf(unjoinableCard, card)),
    ) { viewModel, _ ->
        enable(viewModel)
        advanceTimeBy(60_000)
        runCurrent()
        assertFalse(viewModel.presentation.value.listening)
        assertFalse(viewModel.presentation.value.offersCodeEntry)
    }

    @Test
    fun bluetoothOffDisablesTheGateAndStopsDiscovery() = standbyTest(FakeEventJoinSession()) { viewModel, session ->
        enable(viewModel)
        advanceTimeBy(20_000)
        viewModel.onBluetoothOffChanged(true)
        runCurrent()
        assertEquals(1, session.nearbyEventDiscoveryStopCalls)
        assertFalse(viewModel.presentation.value.listening)
        advanceTimeBy(60_000)
        runCurrent()
        assertFalse(viewModel.presentation.value.offersCodeEntry)
        viewModel.onBluetoothOffChanged(false)
        runCurrent()
        assertEquals(2, session.nearbyEventDiscoveryStartCalls)
    }

    @Test
    fun anAlreadyStartedSessionIsLeftAlone() = standbyTest(FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.Sensing))) { viewModel, session ->
        enable(viewModel)
        advanceTimeBy(60_000)
        runCurrent()
        assertEquals(0, session.nearbyEventDiscoveryStartCalls)
        assertEquals(0, session.nearbyEventDiscoveryStopCalls)
        assertFalse(viewModel.presentation.value.listening)
        assertFalse(viewModel.presentation.value.offersCodeEntry)
    }

    /**
     * A JOIN tap moves the session through permission and registry
     * verification while the candidate it joins must stay in place: leaving
     * the gate there must not clear discovery (iOS: `if isIdle { stop }`).
     */
    @Test
    fun aJoinInFlightClosesTheGateWithoutStoppingDiscovery() = standbyTest(FakeEventJoinSession(nearbyEventCards = listOf(card))) { viewModel, session ->
        enable(viewModel)
        session.emit(EventJoinUiState.RequestingPermission)
        runCurrent()
        session.emit(EventJoinUiState.VerifyingRegistry)
        runCurrent()
        assertEquals(0, session.nearbyEventDiscoveryStopCalls)
        session.emit(EventJoinUiState.JoinFailed(EventJoinFailureReason.NETWORK_REQUIRED))
        runCurrent()
        assertEquals(2, session.nearbyEventDiscoveryStartCalls, "A refused join returns to discovery")
    }

    /** Gate open on Now, then a JOIN tap carries the session into registry verification. */
    private fun TestScope.joinFromNow(viewModel: HomeStandbyViewModel, session: FakeEventJoinSession) {
        enable(viewModel)
        session.emit(EventJoinUiState.RequestingPermission)
        runCurrent()
        session.emit(EventJoinUiState.VerifyingRegistry)
        runCurrent()
        assertEquals(1, session.nearbyEventDiscoveryStartCalls)
        assertEquals(0, session.nearbyEventDiscoveryStopCalls)
    }

    /**
     * Leaving Now while a join is in flight must not stop discovery then (the
     * join still needs its candidate), but once the join is refused and the
     * session is back at rest behind a closed gate, nothing else would ever
     * stop the scan: the gate owes that stop and makes it then.
     */
    @Test
    fun leavingNowDuringAJoinStopsDiscoveryOnceTheJoinIsRefused() = standbyTest(
        FakeEventJoinSession(nearbyEventCards = listOf(card)),
    ) { viewModel, session ->
        joinFromNow(viewModel, session)
        viewModel.onTabSelected(HomeTab.Records)
        runCurrent()
        assertEquals(0, session.nearbyEventDiscoveryStopCalls, "The join in flight still needs its candidate")
        session.emit(EventJoinUiState.JoinFailed(EventJoinFailureReason.NETWORK_REQUIRED))
        runCurrent()
        assertEquals(1, session.nearbyEventDiscoveryStopCalls)
        assertEquals(1, session.nearbyEventDiscoveryStartCalls, "Records never restarts discovery")
        session.emit(EventJoinUiState.Idle)
        runCurrent()
        assertEquals(1, session.nearbyEventDiscoveryStopCalls, "The owed stop is made once")
    }

    @Test
    fun homeLosingResumeDuringAJoinStopsDiscoveryOnceTheJoinIsRefused() = standbyTest(
        FakeEventJoinSession(nearbyEventCards = listOf(card)),
    ) { viewModel, session ->
        joinFromNow(viewModel, session)
        viewModel.onRootResumedChanged(false)
        runCurrent()
        assertEquals(0, session.nearbyEventDiscoveryStopCalls)
        session.emit(EventJoinUiState.PermissionDenied)
        runCurrent()
        assertEquals(1, session.nearbyEventDiscoveryStopCalls)
    }

    /**
     * A join that succeeds hands discovery to the joined session, which owns
     * its own scan (iOS `joinAndStart` clears `discoveryOnlyScanOwned`). When
     * that session later ends, the gate owes nothing on the join's behalf.
     */
    @Test
    fun aSuccessfulJoinDropsTheOwedStop() = standbyTest(
        FakeEventJoinSession(nearbyEventCards = listOf(card)),
    ) { viewModel, session ->
        joinFromNow(viewModel, session)
        viewModel.onTabSelected(HomeTab.Records)
        runCurrent()
        session.emit(EventJoinUiState.Sensing(ScanPhase.Sensing))
        runCurrent()
        session.emit(EventJoinUiState.Idle)
        runCurrent()
        assertEquals(0, session.nearbyEventDiscoveryStopCalls)
        assertEquals(1, session.nearbyEventDiscoveryStartCalls)
    }

    /** Back on Now before the refusal: the open gate keeps discovery, as an unbroken visit would. */
    @Test
    fun returningToNowBeforeTheRefusalKeepsDiscovery() = standbyTest(
        FakeEventJoinSession(nearbyEventCards = listOf(card)),
    ) { viewModel, session ->
        joinFromNow(viewModel, session)
        viewModel.onTabSelected(HomeTab.Records)
        runCurrent()
        viewModel.onTabSelected(HomeTab.Now)
        runCurrent()
        session.emit(EventJoinUiState.JoinFailed(EventJoinFailureReason.NETWORK_REQUIRED))
        runCurrent()
        assertEquals(0, session.nearbyEventDiscoveryStopCalls)
        assertEquals(2, session.nearbyEventDiscoveryStartCalls, "The open gate takes discovery back at rest")
        assertTrue(viewModel.discoveryActive)
    }

    /**
     * Returning to Now and leaving again, both during the join, is still a
     * closed gate at the refusal: the stop is owed exactly as if the user had
     * never come back.
     */
    @Test
    fun leavingNowAgainBeforeTheRefusalStillStopsDiscovery() = standbyTest(
        FakeEventJoinSession(nearbyEventCards = listOf(card)),
    ) { viewModel, session ->
        joinFromNow(viewModel, session)
        viewModel.onTabSelected(HomeTab.Records)
        runCurrent()
        viewModel.onTabSelected(HomeTab.Now)
        runCurrent()
        viewModel.onTabSelected(HomeTab.Records)
        runCurrent()
        session.emit(EventJoinUiState.JoinFailed(EventJoinFailureReason.NETWORK_REQUIRED))
        runCurrent()
        assertEquals(1, session.nearbyEventDiscoveryStopCalls)
    }

    /**
     * The refusal has already reached the session but not yet the gate's
     * collector when the Home entry is cleared: the owed stop is made by
     * [HomeStandbyViewModel.onCleared], because nothing will collect it later.
     */
    @Test
    fun clearingTheHomeEntryWithAnOwedStopAtRestStopsDiscovery() = runTest(dispatcher) {
        val session = FakeEventJoinSession(nearbyEventCards = listOf(card))
        val store = ViewModelStore()
        val viewModel = ViewModelProvider.create(
            store,
            HomeStandbyViewModel.Factory(session) { testScheduler.currentTime },
        )[HomeStandbyViewModel::class.java]
        joinFromNow(viewModel, session)
        viewModel.onTabSelected(HomeTab.Records)
        runCurrent()
        session.emit(EventJoinUiState.JoinFailed(EventJoinFailureReason.NETWORK_REQUIRED))
        store.clear()
        runCurrent()
        assertEquals(1, session.nearbyEventDiscoveryStopCalls)
    }

    /** Cleared while the join is still in flight: the join keeps its candidate, as before. */
    @Test
    fun clearingTheHomeEntryDuringAJoinLeavesDiscoveryToTheJoin() = runTest(dispatcher) {
        val session = FakeEventJoinSession(nearbyEventCards = listOf(card))
        val store = ViewModelStore()
        val viewModel = ViewModelProvider.create(
            store,
            HomeStandbyViewModel.Factory(session) { testScheduler.currentTime },
        )[HomeStandbyViewModel::class.java]
        joinFromNow(viewModel, session)
        viewModel.onTabSelected(HomeTab.Records)
        runCurrent()
        store.clear()
        runCurrent()
        assertEquals(0, session.nearbyEventDiscoveryStopCalls)
    }

    @Test
    fun clearingTheHomeEntryStopsItsDiscovery() = runTest(dispatcher) {
        val session = FakeEventJoinSession()
        val store = ViewModelStore()
        val viewModel = ViewModelProvider.create(
            store,
            HomeStandbyViewModel.Factory(session) { testScheduler.currentTime },
        )[HomeStandbyViewModel::class.java]
        enable(viewModel)
        store.clear()
        assertEquals(1, session.nearbyEventDiscoveryStopCalls)
        assertFalse(viewModel.discoveryActive)
    }
}

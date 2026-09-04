package org.levarac.beid.ui.screens

import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.NearbyEventCard
import org.levarac.beid.sensing.ScanPhase

/**
 * Unit tests for [EventJoinViewModel] against a [FakeEventJoinSession] — no
 * real `Activity`/`BarnardEngine` involved, per #118's seam requirement.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinViewModelTest {
    private val testDispatcher = StandardTestDispatcher()

    @BeforeTest
    fun setUp() {
        Dispatchers.setMain(testDispatcher)
    }

    @AfterTest
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun submittingBlankCodeSetsEmptyCodeFieldErrorAndDoesNotCallSession() = runTest {
        val session = FakeEventJoinSession()
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()

        viewModel.submit()
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(EventJoinFieldError.EmptyCode, viewModel.uiState.value.fieldError)
        assertNull(session.joinedCode)
    }

    @Test
    fun submittingNonBlankCodeClearsFieldErrorAndCallsSessionJoinEvent() = runTest {
        val session = FakeEventJoinSession()
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()

        viewModel.onEventCodeChanged("ABC123")
        viewModel.submit()
        testDispatcher.scheduler.advanceUntilIdle()

        assertNull(viewModel.uiState.value.fieldError)
        assertEquals("abc123", session.joinedCode)
    }

    /**
     * beid#226/DECISIONS 2026-08-20: proves the normalization fix end-to-end
     * through the ViewModel — surrounding whitespace trimmed, then case
     * folded — not just asserted by coincidence on an already-clean string
     * like the test above.
     */
    @Test
    fun submittingCodeWithWhitespaceAndMixedCaseNormalizesBeforeJoining() = runTest {
        val session = FakeEventJoinSession()
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()

        viewModel.onEventCodeChanged("  EthTokyo  ")
        viewModel.submit()
        testDispatcher.scheduler.advanceUntilIdle()

        assertNull(viewModel.uiState.value.fieldError)
        assertEquals("ethtokyo", session.joinedCode)
    }

    @Test
    fun editingEventCodeAfterFieldErrorClearsTheError() = runTest {
        val session = FakeEventJoinSession()
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()
        viewModel.submit()
        testDispatcher.scheduler.advanceUntilIdle()
        assertEquals(EventJoinFieldError.EmptyCode, viewModel.uiState.value.fieldError)

        viewModel.onEventCodeChanged("X")
        testDispatcher.scheduler.advanceUntilIdle()

        assertNull(viewModel.uiState.value.fieldError)
    }

    @Test
    fun uiStateReflectsSessionStateChanges() = runTest {
        val session = FakeEventJoinSession()
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()

        session.emit(EventJoinUiState.Sensing(ScanPhase.Sensing))
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(EventJoinUiState.Sensing(ScanPhase.Sensing), viewModel.uiState.value.sessionState)
    }

    @Test
    fun openAppSettingsDelegatesToSession() {
        val session = FakeEventJoinSession()
        val viewModel = EventJoinViewModel(session)

        viewModel.openAppSettings()

        assertTrue(session.openedAppSettings)
    }

    @Test
    fun simulateSignalLostDelegatesToSession() {
        val session = FakeEventJoinSession()
        val viewModel = EventJoinViewModel(session)

        viewModel.simulateSignalLost()

        assertTrue(session.signalLostSimulated)
    }

    @Test
    fun resumeSensingDelegatesToSession() {
        val session = FakeEventJoinSession()
        val viewModel = EventJoinViewModel(session)

        viewModel.resumeSensing()

        assertTrue(session.sensingResumed)
    }

    @Test
    fun joiningThePreselectedVerifiedOpenCardPassesItsExactEventIdToTheSession() = runTest {
        val eventId = "0x0123456789abcdef"
        val session = FakeEventJoinSession(
            nearbyEventCards = listOf(
                NearbyEventCard(
                    beaconDisplayName = "Beacon name",
                    eventIdHex = eventId,
                    validFromEpochSeconds = 1_700_000_000L,
                    validUntilEpochSeconds = 1_700_003_600L,
                    eventCodeHashHex = "1111111111111111",
                ),
            ),
        )
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()

        viewModel.joinNearbyEvent("1111111111111111")

        assertEquals(eventId, session.joinedDiscoveredEventId)
    }

    @Test
    fun selectionStaysWithItsCandidateAcrossInsertionAndReorderThenFailsClosedAfterExpiry() = runTest {
        val first = NearbyEventCard("First", "0x01", 100L, 200L, "1111111111111111")
        val selected = NearbyEventCard("Selected", "0x02", 100L, 200L, "2222222222222222")
        val inserted = NearbyEventCard("Inserted", "0x03", 100L, 200L, "3333333333333333")
        val session = FakeEventJoinSession(nearbyEventCards = listOf(first, selected))
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()

        session.emitNearbyEventCards(listOf(inserted, selected, first))
        testDispatcher.scheduler.advanceUntilIdle()
        viewModel.joinNearbyEvent(selected.eventCodeHashHex)

        assertEquals("0x02", session.joinedDiscoveredEventId)
        assertEquals(selected.eventCodeHashHex, viewModel.uiState.value.selectedNearbyEventHashHex)

        session.clearJoinedDiscoveredEvent()
        session.emitNearbyEventCards(listOf(inserted, first))
        testDispatcher.scheduler.advanceUntilIdle()
        viewModel.joinNearbyEvent(selected.eventCodeHashHex)

        assertNull(session.joinedDiscoveredEventId, "an expired selection must not retarget another card")
        assertNull(viewModel.uiState.value.selectedNearbyEventHashHex)
    }

    @Test
    fun disappearingSelectionFallsBackToTheOnlyRemainingCandidate() = runTest {
        val selected = NearbyEventCard("Selected", "0x01", 100L, 200L, "1111111111111111")
        val remaining = NearbyEventCard("Remaining", "0x02", 100L, 200L, "2222222222222222")
        val session = FakeEventJoinSession(nearbyEventCards = listOf(selected, remaining))
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()
        assertEquals(selected.eventCodeHashHex, viewModel.uiState.value.selectedNearbyEventHashHex)

        session.emitNearbyEventCards(listOf(remaining))
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(remaining.eventCodeHashHex, viewModel.uiState.value.selectedNearbyEventHashHex)
    }
}

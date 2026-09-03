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
                ),
            ),
        )
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()

        viewModel.joinSelectedNearbyEvent()

        assertEquals(eventId, session.joinedDiscoveredEventId)
    }
}

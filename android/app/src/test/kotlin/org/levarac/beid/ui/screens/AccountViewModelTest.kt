package org.levarac.beid.ui.screens

import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.ScanEventSession
import org.levarac.beid.sensing.ScanPhase

/**
 * Unit tests for [AccountViewModel] against a [FakeEventJoinSession] — no
 * real `Activity`/`BarnardEngine` involved, same seam [EventJoinViewModelTest]
 * uses.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class AccountViewModelTest {
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
    fun leaveEventDelegatesToSession() {
        val session = FakeEventJoinSession()
        val viewModel = AccountViewModel(session)

        viewModel.leaveEvent()

        assertEquals(1, session.leaveEventCallCount)
    }

    @Test
    fun uiStateSeedsFromTheSessionsInitialState() = runTest {
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.Sensing))
        val viewModel = AccountViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(EventJoinUiState.Sensing(ScanPhase.Sensing), viewModel.uiState.value.sessionState)
    }

    @Test
    fun uiStateReflectsSessionStateChanges() = runTest {
        val session = FakeEventJoinSession()
        val viewModel = AccountViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()

        val session1 = ScanEventSession(eventCode = "ABC123")
        session.emit(EventJoinUiState.Sensing(ScanPhase.Recording(session1, peersVerified = 3)))
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(
            EventJoinUiState.Sensing(ScanPhase.Recording(session1, peersVerified = 3)),
            viewModel.uiState.value.sessionState,
        )
    }
}

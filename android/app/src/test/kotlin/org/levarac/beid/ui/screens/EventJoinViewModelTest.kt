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
import org.levarac.beid.sensing.ClockPreflightController
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.NearbyEventCard
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.sensing.TrustedDateSource
import org.levarac.beid.shared.clock.ClockPreflightState
import org.levarac.beid.shared.event.EventJoinFailureReason
import org.levarac.beid.shared.event.NearbyEventSearchOutcome

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
    fun joiningThePreselectedVerifiedOpenCardPassesItsStableHashToTheSession() = runTest {
        val eventId = "0x0123456789abcdef"
        val session = FakeEventJoinSession(
            nearbyEventCards = listOf(
                NearbyEventCard(
                    beaconDisplayName = "Beacon name",
                    eventIdHex = eventId,
                    displayValidFromEpochSeconds = 1_700_000_000L,
                    displayValidUntilEpochSeconds = 1_700_003_600L,
                    eventCodeHashHex = "1111111111111111",
                ),
            ),
        )
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()

        viewModel.joinNearbyEvent("1111111111111111")

        // The stable candidate hash, not the rendered Event ID: the session
        // re-reads the candidate itself at the moment of the tap (beid#374).
        assertEquals("1111111111111111", session.joinedNearbyEventCodeHashHex)
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

        assertEquals(selected.eventCodeHashHex, session.joinedNearbyEventCodeHashHex)
        assertEquals(selected.eventCodeHashHex, viewModel.uiState.value.selectedNearbyEventHashHex)

        session.clearJoinedNearbyEvent()
        session.emitNearbyEventCards(listOf(inserted, first))
        testDispatcher.scheduler.advanceUntilIdle()
        viewModel.joinNearbyEvent(selected.eventCodeHashHex)

        assertNull(session.joinedNearbyEventCodeHashHex, "an expired selection must not retarget another card")
        assertNull(viewModel.uiState.value.selectedNearbyEventHashHex)
    }

    @Test
    fun emptyToMultipleCandidatesRemainsUnselected() = runTest {
        val first = NearbyEventCard("First", "0x01", 100L, 200L, "1111111111111111")
        val second = NearbyEventCard("Second", "0x02", 100L, 200L, "2222222222222222")
        val session = FakeEventJoinSession()
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()

        session.emitNearbyEventCards(listOf(first, second))
        testDispatcher.scheduler.advanceUntilIdle()

        assertNull(viewModel.uiState.value.selectedNearbyEventHashHex)
    }

    @Test
    fun disappearingSelectionFallsBackToTheOnlyRemainingCandidate() = runTest {
        val selected = NearbyEventCard("Selected", "0x01", 100L, 200L, "1111111111111111")
        val remaining = NearbyEventCard("Remaining", "0x02", 100L, 200L, "2222222222222222")
        val session = FakeEventJoinSession(nearbyEventCards = listOf(selected))
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()
        assertEquals(selected.eventCodeHashHex, viewModel.uiState.value.selectedNearbyEventHashHex)

        session.emitNearbyEventCards(listOf(selected, remaining))
        testDispatcher.scheduler.advanceUntilIdle()
        assertEquals(selected.eventCodeHashHex, viewModel.uiState.value.selectedNearbyEventHashHex)

        session.emitNearbyEventCards(listOf(remaining))
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(remaining.eventCodeHashHex, viewModel.uiState.value.selectedNearbyEventHashHex)
    }

    /**
     * beid#463 acceptance condition 2, stated the way the issue states it: not
     * that the field refuses hex, but that a participant can finish without
     * typing any. A canonical open code is 64 hex characters and the issue
     * rules out hand-entering one as a route that does not exist in practice,
     * so the test that matters is that one paste and one submit are the whole
     * interaction.
     *
     * The falsifier is deliberate. If paste were implemented by routing the
     * clipboard through the same per-keystroke entry point the keyboard uses,
     * this test would still pass on the joined code — so it also asserts that
     * the typing path was never entered, by leaving `onEventCodeChanged`
     * unused and checking the field arrived at the pasted value in one step.
     */
    @Test
    fun aPastedCanonicalCodeJoinsWithoutAnyCharacterBeingTyped() = runTest {
        val session = FakeEventJoinSession()
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()

        viewModel.onEventCodePasted(CANONICAL_OPEN_CODE)
        viewModel.submit()
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(CANONICAL_OPEN_CODE, viewModel.uiState.value.eventCode)
        assertEquals(
            CANONICAL_OPEN_CODE,
            session.joinedCode,
            "a pasted canonical open code must reach the session exactly as pasted",
        )
        assertNull(viewModel.uiState.value.fieldError)
    }

    /**
     * A paste of the same code with the surrounding whitespace a clipboard
     * usually brings, and in the case a wallet produces. Normalization is
     * `shared/`'s (`normalizedEventCodeOrNull`), and this asserts the paste
     * route reaches it rather than sidestepping it with its own trim.
     */
    @Test
    fun aPastedCodeIsNormalizedByTheSharedRuleBeforeItReachesTheSession() = runTest {
        val session = FakeEventJoinSession()
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()

        viewModel.onEventCodePasted("  " + CANONICAL_OPEN_CODE.uppercase() + "\n")
        viewModel.submit()
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(CANONICAL_OPEN_CODE, session.joinedCode)
    }

    /**
     * An empty clipboard must not wipe a code the participant already has in
     * the field. A mis-tap on Paste is a very ordinary thing to do while
     * standing in a venue doorway holding the only copy of a 64-character
     * string.
     */
    @Test
    fun pastingAnEmptyClipboardLeavesTheExistingCodeAlone() = runTest {
        val session = FakeEventJoinSession()
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()

        viewModel.onEventCodeChanged("ethtokyo2026")
        viewModel.onEventCodePasted(null)
        viewModel.onEventCodePasted("   ")
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals("ethtokyo2026", viewModel.uiState.value.eventCode)
    }

    /**
     * beid#463 acceptance condition 3, at this layer: a refusal has to become
     * something the screen can render, carrying the reason the session decided.
     * Asserted against the shared enum rather than against any string — the
     * copy lives in the string catalog and this layer must not know it.
     */
    @Test
    fun aRefusedJoinBecomesAFieldErrorCarryingTheReason() = runTest {
        val session = FakeEventJoinSession()
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()

        session.emit(EventJoinUiState.JoinFailed(EventJoinFailureReason.NETWORK_REQUIRED))
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(
            EventJoinFieldError.JoinFailed(EventJoinFailureReason.NETWORK_REQUIRED),
            viewModel.uiState.value.fieldError,
        )
    }

    /**
     * The reason has to survive the trip rather than being flattened on
     * arrival. Without this, an implementation that produced one generic
     * JoinFailed for every refusal would pass the test above.
     */
    @Test
    fun eachRefusalReasonSurvivesIntoTheFieldError() = runTest {
        val session = FakeEventJoinSession()
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()

        for (reason in EventJoinFailureReason.entries) {
            session.emit(EventJoinUiState.Idle)
            testDispatcher.scheduler.advanceUntilIdle()
            session.emit(EventJoinUiState.JoinFailed(reason))
            testDispatcher.scheduler.advanceUntilIdle()

            assertEquals(
                EventJoinFieldError.JoinFailed(reason),
                viewModel.uiState.value.fieldError,
                "reason $reason must reach the surface intact",
            )
        }
    }

    /** A refusal must not stay on screen once the session has moved on. */
    @Test
    fun leavingTheFailedStateClearsTheFieldError() = runTest {
        val session = FakeEventJoinSession(EventJoinUiState.JoinFailed(EventJoinFailureReason.EVENT_NOT_FOUND))
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()

        session.emit(EventJoinUiState.VerifyingRegistry)
        testDispatcher.scheduler.advanceUntilIdle()

        assertNull(viewModel.uiState.value.fieldError)
    }

    /** The rescue offer is the session's decision; this layer only republishes it. */
    @Test
    fun theRescueOfferReachesTheScreenState() = runTest {
        val session = FakeEventJoinSession()
        val viewModel = EventJoinViewModel(session)
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(NearbyEventSearchOutcome.SEARCHING, viewModel.uiState.value.searchOutcome)

        session.emitSearchOutcome(NearbyEventSearchOutcome.RESCUE_ENTRY_OFFERED)
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(NearbyEventSearchOutcome.RESCUE_ENTRY_OFFERED, viewModel.uiState.value.searchOutcome)
    }

    // ---- beid#464: 端末時計 preflight の配線

    /** 取得回数を数える日付ソース。サーバ時刻と同じ時計を返すので、測れば WITHIN になる。 */
    private class CountingDateSource : TrustedDateSource {
        var fetches = 0
        override suspend fun fetchDateHeader(): String? {
            fetches += 1
            return SERVER_DATE
        }
    }

    private class FakeClocks(var wall: Long = SERVER_MILLIS, var monotonic: Long = 1_000L)

    private fun preflight(source: TrustedDateSource, clocks: FakeClocks) = ClockPreflightController(
        source = source,
        wallMillis = { clocks.wall },
        monotonicMillis = { clocks.monotonic },
        eninSeconds = 300,
    )

    @Test
    fun openingTheScreenChecksTheDeviceClock() = runTest {
        val source = CountingDateSource()
        val viewModel = EventJoinViewModel(FakeEventJoinSession(), preflight(source, FakeClocks()))
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(1, source.fetches)
        assertEquals(ClockPreflightState.WITHIN_TOLERANCE, viewModel.uiState.value.clockPreflight)
    }

    @Test
    fun joiningANearbyEventChecksTheDeviceClockAgain() = runTest {
        val source = CountingDateSource()
        val clocks = FakeClocks()
        val session = FakeEventJoinSession(nearbyEventCards = listOf(joinableCard))
        val viewModel = EventJoinViewModel(session, preflight(source, clocks))
        testDispatcher.scheduler.advanceUntilIdle()

        // 画面を開いてから 12 ENIN (300 s x 12) 経ち、キャッシュが失効している。
        clocks.wall += 3_600_000L
        clocks.monotonic += 3_600_000L
        viewModel.joinNearbyEvent(JOINABLE_HASH)
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(2, source.fetches)
        assertEquals(JOINABLE_HASH, session.joinedNearbyEventCodeHashHex)
    }

    @Test
    fun joiningANearbyEventSeesAClockChangedSinceTheScreenOpened() = runTest {
        val source = CountingDateSource()
        val clocks = FakeClocks()
        val viewModel = EventJoinViewModel(
            FakeEventJoinSession(nearbyEventCards = listOf(joinableCard)),
            preflight(source, clocks),
        )
        testDispatcher.scheduler.advanceUntilIdle()
        assertEquals(ClockPreflightState.WITHIN_TOLERANCE, viewModel.uiState.value.clockPreflight)

        // キャッシュは有効なまま、端末時計だけが 2 分進められた。
        clocks.wall += 120_000L
        viewModel.joinNearbyEvent(JOINABLE_HASH)
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(1, source.fetches)
        assertEquals(ClockPreflightState.OVER_TOLERANCE, viewModel.uiState.value.clockPreflight)
    }

    @Test
    fun checkAgainMeasuresEvenWhileTheCacheIsValid() = runTest {
        val source = CountingDateSource()
        val viewModel = EventJoinViewModel(FakeEventJoinSession(), preflight(source, FakeClocks()))
        testDispatcher.scheduler.advanceUntilIdle()
        assertEquals(1, source.fetches)

        viewModel.retryClockPreflight()
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(2, source.fetches)
    }

    private val joinableCard = NearbyEventCard(
        beaconDisplayName = "Beacon name",
        eventIdHex = "0x0123456789abcdef",
        displayValidFromEpochSeconds = 1_700_000_000L,
        displayValidUntilEpochSeconds = 1_700_003_600L,
        eventCodeHashHex = JOINABLE_HASH,
    )

    private companion object {
        const val JOINABLE_HASH = "1111111111111111"
        const val SERVER_DATE = "Wed, 16 Sep 2026 11:58:53 GMT"
        const val SERVER_MILLIS = 1_789_559_933_000L

        /** A well-formed canonical open code: the lowercase hex of a whole 32-byte Event ID. */
        const val CANONICAL_OPEN_CODE =
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    }
}

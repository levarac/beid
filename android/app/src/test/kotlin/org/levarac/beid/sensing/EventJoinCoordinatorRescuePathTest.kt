package org.levarac.beid.sensing

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.shared.event.EventJoinFailureReason
import org.levarac.beid.shared.event.NearbyEventSearchOutcome
import org.levarac.beid.shared.event.RESCUE_ENTRY_DELAY_SECONDS
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

/**
 * beid#463 — the rescue path for a participant whose radio finds nothing.
 *
 * Two claims, and they are separate on purpose. The first is that the route
 * becomes reachable at all: a search that runs its course without finding
 * anything joinable has to offer code entry, because until this issue that
 * affordance existed only behind the Account screen and nobody stuck in a
 * doorway would think to look there. The second is that a refusal says which
 * refusal it was — a participant who cannot reach the network and a
 * participant holding a truncated code are in different situations and were
 * being told the same sentence.
 *
 * What is *not* here: whether the shared gate binds a canonical open code to
 * the Event ID that came back. That decision is `shared/`'s and is proven in
 * `RegistryVerifiedJoinContextTest`, where a successful registry answer can be
 * constructed. This module deliberately cannot build one — see
 * [FakeEventJoinRegistry] — and a test here that appeared to prove it would be
 * proving something weaker while reading like the real thing.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorRescuePathTest {
    @Test
    fun aSearchThatHasJustStartedDoesNotYetOfferTheRescueRoute() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)

        coordinator.startNearbyEventDiscovery()
        runCurrent()

        assertEquals(NearbyEventSearchOutcome.SEARCHING, coordinator.nearbyEventSearchOutcome.value)
    }

    /**
     * Acceptance condition 1. The timeout is real elapsed time on the
     * coordinator's own clock, advanced here through the test scheduler, so
     * this exercises the same countdown production runs rather than a
     * test-only shortcut into the offered state.
     */
    @Test
    fun aSearchThatFoundNothingJoinableOffersTheRescueRoute() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)

        coordinator.startNearbyEventDiscovery()
        runCurrent()
        advanceTimeBy(RESCUE_ENTRY_DELAY_SECONDS * 1_000L + 1L)
        runCurrent()

        assertEquals(
            NearbyEventSearchOutcome.RESCUE_ENTRY_OFFERED,
            coordinator.nearbyEventSearchOutcome.value,
        )
    }

    /**
     * The boundary an implementation keyed on "the card list is empty" gets
     * wrong. A candidate seen on the radio but not resolved to an Event ID
     * renders a card and cannot be joined, so the participant is in exactly
     * the dead end this route exists for while the screen looks busy.
     */
    @Test
    fun aCandidateThatCannotBeJoinedDoesNotSuppressTheRescueRoute() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)

        coordinator.startNearbyEventDiscovery()
        runCurrent()
        engine.emitVerifiedEnvelopeV2(
            "peripheral-vector",
            NearbyEventPromotionFixture.CONTAINER,
            NearbyEventPromotionFixture.ENIN,
        )
        runCurrent()
        advanceTimeBy(RESCUE_ENTRY_DELAY_SECONDS * 1_000L + 1L)
        runCurrent()

        assertEquals(
            1,
            coordinator.nearbyEventCards.value.size,
            "the precondition of this test is a card on screen; without one it proves nothing",
        )
        assertEquals(
            0,
            coordinator.nearbyEventCards.value.count { it.eventIdHex != null },
            "and that card must be one that cannot be joined",
        )
        assertEquals(
            NearbyEventSearchOutcome.RESCUE_ENTRY_OFFERED,
            coordinator.nearbyEventSearchOutcome.value,
        )
    }

    /**
     * The other direction, and the reason the offer is not simply latched on
     * at the threshold: a registry read that completes late makes a candidate
     * joinable, and the participant now has something to tap.
     */
    @Test
    fun aCandidateThatBecomesJoinableWithdrawsTheRescueOffer() = runTest {
        val engine = FakeEventJoinEngine()
        val nearby = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, nearbyRegistry = nearby)

        coordinator.startNearbyEventDiscovery()
        runCurrent()
        advanceTimeBy(RESCUE_ENTRY_DELAY_SECONDS * 1_000L + 1L)
        runCurrent()
        assertEquals(
            NearbyEventSearchOutcome.RESCUE_ENTRY_OFFERED,
            coordinator.nearbyEventSearchOutcome.value,
            "the precondition is a standing rescue offer",
        )

        promoteVectorCandidate(engine, nearby)

        assertEquals(
            1,
            coordinator.nearbyEventCards.value.count { it.eventIdHex != null },
            "the promotion must actually have produced a joinable card",
        )
        assertEquals(NearbyEventSearchOutcome.SEARCHING, coordinator.nearbyEventSearchOutcome.value)
    }

    /**
     * Leaving the surface ends the search. Without clearing the start time the
     * next visit would inherit this one's elapsed value and offer rescue
     * immediately, which reads to a participant as the app having given up
     * before it looked.
     */
    @Test
    fun leavingTheSurfaceWithdrawsTheOfferAndRestartsTheClock() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)

        coordinator.startNearbyEventDiscovery()
        runCurrent()
        advanceTimeBy(RESCUE_ENTRY_DELAY_SECONDS * 1_000L + 1L)
        runCurrent()
        coordinator.stopNearbyEventDiscovery()
        runCurrent()

        assertEquals(NearbyEventSearchOutcome.SEARCHING, coordinator.nearbyEventSearchOutcome.value)

        coordinator.startNearbyEventDiscovery()
        runCurrent()

        // Without this the test can pass for the wrong reason: if the restart
        // had silently early-returned, the outcome would read SEARCHING
        // because nothing was running, not because the clock was reset.
        assertEquals(
            2,
            engine.startScanCalls,
            "the second search must actually have started for this assertion to mean anything",
        )
        assertEquals(
            NearbyEventSearchOutcome.SEARCHING,
            coordinator.nearbyEventSearchOutcome.value,
            "a fresh search must be timed from when it began, not from the last one",
        )
    }

    /**
     * Acceptance condition 3. The registry could not be reached, and that has
     * to arrive at the surface as a network problem rather than as a generic
     * refusal — the participant has no other way to tell "no event here" from
     * "this phone is offline", which is the whole reason the rescue route
     * needed a message of its own.
     */
    @Test
    fun aLookupThatCouldNotReachTheNetworkReportsANetworkFailure() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(
            engine,
            joinRegistry = FakeEventJoinRegistry(
                answer = FakeEventJoinRegistry.Answer.LOOKUP_FAILS,
                errorCode = "event_code_lookup_http_error",
            ),
        )

        coordinator.joinEvent(CANONICAL_OPEN_CODE)
        runCurrent()

        val state = assertIs<EventJoinUiState.JoinFailed>(coordinator.state.value)
        assertEquals(EventJoinFailureReason.NETWORK_REQUIRED, state.reason)
    }

    /**
     * The same refusal one step later: the code routed and the definition read
     * itself could not reach the network. Both legs have to classify, because
     * a fresh install with no cached definition fails at whichever one it
     * reaches first and the participant's situation is identical either way.
     */
    @Test
    fun aDefinitionReadThatCouldNotReachTheNetworkReportsANetworkFailure() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(
            engine,
            joinRegistry = FakeEventJoinRegistry(
                answer = FakeEventJoinRegistry.Answer.DEFINITION_FAILS,
                errorCode = "timeout",
            ),
        )

        coordinator.joinEvent(CANONICAL_OPEN_CODE)
        runCurrent()

        val state = assertIs<EventJoinUiState.JoinFailed>(coordinator.state.value)
        assertEquals(EventJoinFailureReason.NETWORK_REQUIRED, state.reason)
    }

    /**
     * And the control that makes the two above mean something. A mapping that
     * answered NETWORK_REQUIRED for every failure would pass both of them; a
     * code that no event is registered for must not send the participant
     * looking for a better connection.
     */
    @Test
    fun aCodeNoEventIsRegisteredForIsNotReportedAsANetworkFailure() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(
            engine,
            joinRegistry = FakeEventJoinRegistry(
                answer = FakeEventJoinRegistry.Answer.LOOKUP_FAILS,
                errorCode = "event_code_lookup_not_found",
            ),
        )

        coordinator.joinEvent(CANONICAL_OPEN_CODE)
        runCurrent()

        val state = assertIs<EventJoinUiState.JoinFailed>(coordinator.state.value)
        assertEquals(EventJoinFailureReason.EVENT_NOT_FOUND, state.reason)
    }

    /**
     * A deployment with no registry configured at all. It cannot verify
     * anything, which looks from the outside exactly like being offline and is
     * not fixed by finding Wi-Fi.
     */
    @Test
    fun aDeploymentWithNoRegistryIsNotReportedAsANetworkFailure() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, joinRegistry = null)

        coordinator.joinEvent(CANONICAL_OPEN_CODE)
        runCurrent()

        val state = assertIs<EventJoinUiState.JoinFailed>(coordinator.state.value)
        assertEquals(EventJoinFailureReason.VERIFICATION_FAILED, state.reason)
    }

    /**
     * A failure the registry did not name stays UNKNOWN. Guessing here would
     * be the worst available outcome: a confident, specific, wrong instruction
     * to a participant who has no way to check it.
     */
    @Test
    fun anUnnamedFailureIsNotGuessedAt() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(
            engine,
            joinRegistry = FakeEventJoinRegistry(FakeEventJoinRegistry.Answer.LOOKUP_FAILS),
        )

        coordinator.joinEvent(CANONICAL_OPEN_CODE)
        runCurrent()

        val state = assertIs<EventJoinUiState.JoinFailed>(coordinator.state.value)
        assertEquals(EventJoinFailureReason.UNKNOWN, state.reason)
    }

    private fun TestScope.coordinator(
        engine: FakeEventJoinEngine,
        joinRegistry: FakeEventJoinRegistry? = FakeEventJoinRegistry(),
        nearbyRegistry: FakeNearbyEventRegistry = FakeNearbyEventRegistry(),
    ): EventJoinCoordinator = EventJoinCoordinator(
        engine = engine,
        joinRegistry = joinRegistry,
        nearbyRegistry = nearbyRegistry,
        nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS + testScheduler.currentTime },
        coroutineScope = backgroundScope,
        sensingCryptography = FakeSensingCryptography(),
        selfProofRecordStore = SelfProofRecordStore(newTempRecordFile("rescue-self-proofs")),
        bindingRecordStore = BindingRecordStore(newTempRecordFile("rescue-binding-records")),
    )

    private companion object {
        /**
         * A canonical open code — the lowercase hex of a whole 32-byte Event
         * ID, which is what a participant pastes on this route. Used here so
         * these refusals are exercised on the shape the rescue path actually
         * carries, not on a short placeholder string.
         */
        const val CANONICAL_OPEN_CODE =
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    }
}

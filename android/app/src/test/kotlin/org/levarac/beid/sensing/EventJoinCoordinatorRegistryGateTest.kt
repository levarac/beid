package org.levarac.beid.sensing

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * beid#374 — join, key use, recording and relay are permitted only after this
 * host's own registry read verified the event (spec 122's `REGISTRY_VERIFIED`).
 *
 * `joinEventStartsNeitherJoinNorSensingWhenNoRegistryIsConfigured` → iOS `testStartSensingLeavesNoSensingScreenWhenNoRegistryIsConfigured`.
 * `joinEventStartsNeitherJoinNorSensingWhenTheRegistryLookupFails` → iOS `testStartSensingStartsNeitherJoinNorSensingWhenTheRegistryReadFails`.
 * `joinEventStartsNeitherJoinNorSensingWhileTheRegistryLookupIsPending` → iOS `testStartSensingStartsNeitherJoinNorSensingWhileTheRegistryReadIsPending`.
 * `aRefusedJoinLeavesNoRecordingAndNoRelay` → iOS `testARefusedJoinLeavesNoRecordingAndNoRelay` (same name on both).
 *
 * Four of this class's ten tests are paired above. The remaining six have no
 * counterpart that is obvious from the iOS names, and are deliberately left
 * unpaired rather than recorded as absent: naming a twin that exists stays true
 * on its own, while asserting that one does NOT exist is the construct that made
 * this comment stale in the first place. Check the iOS file rather than trusting
 * a list here.
 *
 * "Pending" is expressed by a registry that never answers, not by a timer:
 * that is exactly the state a slow or unreachable operator endpoint leaves the
 * app in, and it is the case the old code failed hardest — it had already
 * joined and started sensing before the first byte came back.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorRegistryGateTest {
    @Test
    fun joinEventStartsNeitherJoinNorSensingWhenTheRegistryLookupFails() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeEventJoinRegistry(FakeEventJoinRegistry.Answer.LOOKUP_FAILS)
        val coordinator = coordinator(engine, registry)

        coordinator.joinEvent("UNREGISTERED-EVENT")
        runCurrent()

        assertNoJoinAndNoSensing(engine, coordinator)
        assertIs<EventJoinUiState.JoinFailed>(coordinator.state.value)
    }

    @Test
    fun aRegistryRejectionIsWrittenToTheReplaceableJoinDiagnosticSink() = runTest {
        val engine = FakeEventJoinEngine()
        val lines = mutableListOf<String>()
        val coordinator = coordinator(
            engine,
            FakeEventJoinRegistry(FakeEventJoinRegistry.Answer.LOOKUP_FAILS),
            diagnosticLog = lines::add,
        )

        coordinator.joinEvent("UNREGISTERED-EVENT")
        runCurrent()

        assertTrue(
            lines.contains(
                "join_stage event_id=unknown stage=admission outcome=rejected_unknown " +
                    "attempt=none retry_at_epoch_ms=none",
            ),
            "diagnostic lines: $lines",
        )
    }

    /**
     * The definition read comes back **empty**, which is what a failed read
     * looks like on this side: `EventJoinRegistry`'s adapter filters a
     * non-successful resolution to `null` before the gate sees it.
     *
     * Renamed in beid#434. It used to be called
     * `…WhenTheDefinitionDoesNotVerify`, which promises the *other* refusal —
     * a definition that arrives and is then judged ineligible. This drives
     * neither more nor less than a null read: `FakeEventJoinRegistry.Answer`
     * has `DEFINITION_FAILS` succeed the routing call and return `null` from
     * `resolveEventDefinition`, exactly as `LOOKUP_FAILS` does. **The two
     * answers differ only in whether `resolveEventId` succeeds.**
     *
     * The ineligible case is not reachable from this module at all: the
     * fake cannot build a non-null `EventDefinitionResolution`, because that
     * type's constructor is `internal` to `shared/` — which is the seam
     * beid#434 exists to add.
     */
    @Test
    fun joinEventStartsNeitherJoinNorSensingWhenTheDefinitionReadReturnsNothing() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeEventJoinRegistry(FakeEventJoinRegistry.Answer.DEFINITION_FAILS)
        val coordinator = coordinator(engine, registry)

        coordinator.joinEvent("ROUTED-BUT-UNVERIFIABLE")
        runCurrent()

        // Pins this test's own name (beid#434). Without it the name is true and
        // nothing enforces it: every assertion below passes just as well when
        // the routing call fails and no definition read is ever made, so the
        // name would silently become false the moment someone edited
        // `FakeEventJoinRegistry.Answer.DEFINITION_FAILS`. Same idiom as
        // `joinEventStartsNeitherJoinNorSensingWhileTheDefinitionReadIsPending`.
        assertEquals(
            1,
            registry.definitionRequests,
            "the definition read must actually have happened for it to have returned nothing",
        )
        assertNoJoinAndNoSensing(engine, coordinator)
        assertIs<EventJoinUiState.JoinFailed>(
            coordinator.state.value,
            "an Event ID that routes but whose definition read comes back empty is not a verified event",
        )
    }

    /**
     * beid#434 — the branch iOS calls `definitionNotEligible`.
     *
     * A read that succeeded is not by itself permission to join. Until the
     * shared test factory landed (beid#473) this could not be expressed from a
     * test on either platform, so a regression that admitted an ineligible
     * definition would have kept both suites green.
     *
     * The definition here is valid and inside its window; the only thing wrong
     * with it is that it is not open admission. So a refusal can only have come
     * from the eligibility rule.
     */
    @Test
    fun joinEventStartsNeitherJoinNorSensingWhenTheDefinitionIsNotOpenAdmission() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeEventJoinRegistry(FakeEventJoinRegistry.Answer.DEFINITION_NOT_ELIGIBLE)
        val coordinator = coordinator(engine, registry)

        coordinator.joinEvent("GATED-EVENT")
        runCurrent()

        assertEquals(1, registry.definitionRequests, "the gate must have reached the definition read")
        assertNoJoinAndNoSensing(engine, coordinator)
        assertIs<EventJoinUiState.JoinFailed>(coordinator.state.value)
    }

    @Test
    fun joinEventStartsNeitherJoinNorSensingWhileTheRegistryLookupIsPending() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeEventJoinRegistry(FakeEventJoinRegistry.Answer.HOLDS)
        val coordinator = coordinator(engine, registry)

        coordinator.joinEvent("SLOW-EVENT")
        runCurrent()

        assertEquals(1, registry.lookupRequests, "the gate must actually have asked the registry")
        assertNoJoinAndNoSensing(engine, coordinator)
        assertEquals(
            EventJoinUiState.VerifyingRegistry,
            coordinator.state.value,
            "a read still in flight is neither a join nor a failure",
        )
    }

    @Test
    fun joinEventStartsNeitherJoinNorSensingWhileTheDefinitionReadIsPending() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeEventJoinRegistry(FakeEventJoinRegistry.Answer.HOLDS)
        val coordinator = coordinator(engine, registry)

        coordinator.joinEvent("SLOW-EVENT")
        runCurrent()
        registry.completeHeldLookup()
        runCurrent()

        assertEquals(1, registry.definitionRequests, "routing alone must not satisfy the gate")
        assertNoJoinAndNoSensing(engine, coordinator)
        assertEquals(EventJoinUiState.VerifyingRegistry, coordinator.state.value)
    }

    // DELETED, and deliberately: the code-entry SUCCESS case cannot be
    // expressed in this module. Its evidence is an EventDefinitionResolution,
    // whose constructor is internal to shared, so no app-module fake can
    // produce one -- which is the unforgeability this round is built on rather
    // than a gap in the fixture. That case is proven in shared by
    // RegistryVerifiedJoinContextTest's operator-lookup suite. The code-entry
    // FAILED and PENDING cases remain here, above, because those a fake can
    // express by answering null or by never answering.

    @Test
    fun joinEventStartsNeitherJoinNorSensingWhenNoRegistryIsConfigured() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, joinRegistry = null)

        coordinator.joinEvent("ANY-EVENT")
        runCurrent()

        assertNoJoinAndNoSensing(engine, coordinator)
        assertIs<EventJoinUiState.JoinFailed>(
            coordinator.state.value,
            "a deployment with no registry cannot verify anything, so it cannot join anything",
        )
    }

    /**
     * A candidate barnard verified on the radio but that the registry never
     * confirmed. The strongest refusal on this path, because everything except
     * the registry's own answer is present.
     */
    @Test
    fun joinNearbyEventStartsNeitherJoinNorSensingForARadioSelfVerifiedCandidate() = runTest {
        val engine = FakeEventJoinEngine()
        val nearby = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, FakeEventJoinRegistry(), nearby)
        engine.emitVerifiedEnvelopeV2(
            "peripheral-vector",
            NearbyEventPromotionFixture.CONTAINER,
            NearbyEventPromotionFixture.ENIN,
        )
        runCurrent()

        coordinator.joinNearbyEvent(NearbyEventPromotionFixture.EVENT_CODE_HASH)
        runCurrent()

        assertNoJoinAndNoSensing(engine, coordinator)
        assertIs<EventJoinUiState.JoinFailed>(coordinator.state.value)
    }

    /**
     * The nearby path performs no registry read at the tap -- shape (a) issues
     * from what the promotion already retained -- so there is no pending state
     * to observe here. What remains representable, and what actually matters,
     * is that a card with no promoted candidate behind it joins nothing.
     */
    @Test
    fun joinNearbyEventStartsNeitherJoinNorSensingForACandidateThatWasNeverPromoted() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeEventJoinRegistry())

        coordinator.joinNearbyEvent(NearbyEventPromotionFixture.EVENT_CODE_HASH)
        runCurrent()

        assertNoJoinAndNoSensing(engine, coordinator)
        assertIs<EventJoinUiState.JoinFailed>(coordinator.state.value)
    }

    @Test
    fun joinNearbyEventStartsJoinAndSensingOnceTheCandidateIsRegistryVerified() = runTest {
        val engine = FakeEventJoinEngine()
        val nearby = FakeNearbyEventRegistry()
        val joinRegistry = FakeEventJoinRegistry()
        val lines = mutableListOf<String>()
        val coordinator = coordinator(engine, joinRegistry, nearby, diagnosticLog = lines::add)

        joinPromotedVectorEvent(coordinator, engine, nearby)

        assertEquals(1, engine.joinEventCalls)
        assertEquals(NearbyEventPromotionFixture.EVENT_ID_HEX, engine.getCurrentEventCode())
        assertIs<EventJoinUiState.Sensing>(coordinator.state.value)
        assertEquals(
            0,
            joinRegistry.lookupRequests + joinRegistry.definitionRequests,
            "shape (a) issues from retained promotion evidence and reads the registry again for nothing",
        )
        assertTrue(
            lines.contains(
                "join_stage event_id=5d5891b9 stage=admission outcome=admitted " +
                    "attempt=none retry_at_epoch_ms=none",
            ),
            "diagnostic lines: $lines",
        )
    }

    /**
     * The user gave up while the read was outstanding. Its late answer belongs
     * to a session that no longer exists and must not resurrect it — the
     * failure the old code could not have, because it had already joined.
     */
    @Test
    fun aVerificationThatAnswersAfterTheUserLeftStartsNothing() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeEventJoinRegistry(FakeEventJoinRegistry.Answer.HOLDS)
        val coordinator = coordinator(engine, registry)
        coordinator.joinEvent("ABANDONED-EVENT")
        runCurrent()

        coordinator.leaveEvent()
        registry.completeHeldLookup()
        runCurrent()
        registry.completeHeldDefinition()
        runCurrent()

        assertNoJoinAndNoSensing(engine, coordinator)
        assertEquals(EventJoinUiState.Idle, coordinator.state.value)
    }

    @Test
    fun aRefusedJoinLeavesNoRecordingAndNoRelay() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeEventJoinRegistry(FakeEventJoinRegistry.Answer.LOOKUP_FAILS))
        coordinator.joinEvent("UNREGISTERED-EVENT")
        runCurrent()

        // Detections keep arriving from the radio whether or not this device
        // joined; none of them may start a recording session.
        engine.emitDetection(enin = 1, rpid = "aa", detectedDisplayId = "device-1")
        engine.emitDetection(enin = 2, rpid = "bb", detectedDisplayId = "device-2")
        engine.emitDetection(enin = 3, rpid = "cc", detectedDisplayId = "device-3")

        assertNull(engine.configuredRelayVerifier, "an unverified event may not be relayed")
        assertNull(coordinator.relayGateJoinedEventIdHexForTesting)
        assertTrue(
            coordinator.state.value !is EventJoinUiState.Sensing,
            "detections must not carry a refused join into a recording session",
        )
    }

    private fun assertNoJoinAndNoSensing(engine: FakeEventJoinEngine, coordinator: EventJoinCoordinator) {
        assertEquals(0, engine.joinEventCalls, "no join may be attempted before the registry verifies the event")
        assertNull(engine.getCurrentEventCode())
        assertEquals(0, engine.startAutoCalls, "no sensing may start before the registry verifies the event")
        assertTrue(coordinator.state.value !is EventJoinUiState.Sensing)
        assertNull(engine.configuredRelayVerifier, "relay may not be configured for an unverified event")
    }

    private fun TestScope.coordinator(
        engine: FakeEventJoinEngine,
        joinRegistry: FakeEventJoinRegistry?,
        nearbyRegistry: FakeNearbyEventRegistry = FakeNearbyEventRegistry(),
        diagnosticLog: (String) -> Unit = {},
    ): EventJoinCoordinator = EventJoinCoordinator(
        engine = engine,
        joinRegistry = joinRegistry,
        nearbyRegistry = nearbyRegistry,
        nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS + testScheduler.currentTime },
        coroutineScope = backgroundScope,
        sensingCryptography = FakeSensingCryptography(),
        selfProofRecordStore = SelfProofRecordStore(newTempRecordFile("gate-self-proofs")),
        bindingRecordStore = BindingRecordStore(newTempRecordFile("gate-binding-records")),
        joinDiagnostics = diagnosticLog,
    )
}

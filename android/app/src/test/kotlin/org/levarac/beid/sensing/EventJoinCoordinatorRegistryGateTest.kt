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
 * Named for the behaviour rather than the mechanism so the iOS counterpart can
 * mirror them one for one: iOS's `SensingCoordinator.joinEvent(_:canonicalEventIdHex:)`
 * still takes an optional ID and joins whatever the lookup returned, so these
 * three cases have no iOS twin yet.
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
        assertEquals(EventJoinUiState.JoinFailed, coordinator.state.value)
    }

    @Test
    fun joinEventStartsNeitherJoinNorSensingWhenTheDefinitionDoesNotVerify() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeEventJoinRegistry(FakeEventJoinRegistry.Answer.DEFINITION_FAILS)
        val coordinator = coordinator(engine, registry)

        coordinator.joinEvent("ROUTED-BUT-UNVERIFIABLE")
        runCurrent()

        assertNoJoinAndNoSensing(engine, coordinator)
        assertEquals(
            EventJoinUiState.JoinFailed,
            coordinator.state.value,
            "an Event ID that routes but whose definition does not verify is not a verified event",
        )
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

    @Test
    fun joinEventStartsJoinAndSensingOnceTheRegistryVerifiesTheEvent() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeEventJoinRegistry())

        coordinator.joinEvent("VERIFIED-EVENT")
        runCurrent()

        assertEquals(1, engine.joinEventCalls)
        assertEquals("VERIFIED-EVENT", engine.getCurrentEventCode())
        assertEquals(1, engine.startAutoCalls)
        assertIs<EventJoinUiState.Sensing>(coordinator.state.value)
        assertEquals(
            FakeEventJoinRegistry.DEFAULT_EVENT_ID_HEX,
            coordinator.relayGateJoinedEventIdHexForTesting,
            "the verified Event ID is what opens the relay gate",
        )
    }

    @Test
    fun joinEventStartsNeitherJoinNorSensingWhenNoRegistryIsConfigured() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, joinRegistry = null)

        coordinator.joinEvent("ANY-EVENT")
        runCurrent()

        assertNoJoinAndNoSensing(engine, coordinator)
        assertEquals(
            EventJoinUiState.JoinFailed,
            coordinator.state.value,
            "a deployment with no registry cannot verify anything, so it cannot join anything",
        )
    }

    @Test
    fun joinNearbyEventStartsNeitherJoinNorSensingWhenTheRegistryVerificationFails() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeEventJoinRegistry(FakeEventJoinRegistry.Answer.DEFINITION_FAILS)
        val coordinator = coordinator(engine, registry)

        coordinator.joinNearbyEvent(FakeEventJoinRegistry.DEFAULT_EVENT_ID_HEX)
        runCurrent()

        assertNoJoinAndNoSensing(engine, coordinator)
        assertEquals(EventJoinUiState.JoinFailed, coordinator.state.value)
    }

    @Test
    fun joinNearbyEventStartsNeitherJoinNorSensingWhileTheRegistryVerificationIsPending() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeEventJoinRegistry(FakeEventJoinRegistry.Answer.HOLDS)
        val coordinator = coordinator(engine, registry)

        coordinator.joinNearbyEvent(FakeEventJoinRegistry.DEFAULT_EVENT_ID_HEX)
        runCurrent()

        assertNoJoinAndNoSensing(engine, coordinator)
        assertEquals(EventJoinUiState.VerifyingRegistry, coordinator.state.value)
    }

    @Test
    fun joinNearbyEventStartsJoinAndSensingOnceTheRegistryVerifiesTheEvent() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeEventJoinRegistry()
        val coordinator = coordinator(engine, registry)

        coordinator.joinNearbyEvent(FakeEventJoinRegistry.DEFAULT_EVENT_ID_HEX)
        runCurrent()

        assertEquals(1, engine.joinEventCalls)
        assertIs<EventJoinUiState.Sensing>(coordinator.state.value)
        assertEquals(
            0,
            registry.lookupRequests,
            "a card already carries the canonical Event ID, so there is nothing to route",
        )
        assertEquals(1, registry.definitionRequests, "the card's Event ID is still verified here, not inherited")
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
    ): EventJoinCoordinator = EventJoinCoordinator(
        engine = engine,
        joinRegistry = joinRegistry,
        nowEpochMillis = { testScheduler.currentTime },
        coroutineScope = backgroundScope,
        sensingCryptography = FakeSensingCryptography(),
        selfProofRecordStore = SelfProofRecordStore(newTempRecordFile("gate-self-proofs")),
        bindingRecordStore = BindingRecordStore(newTempRecordFile("gate-binding-records")),
    )
}

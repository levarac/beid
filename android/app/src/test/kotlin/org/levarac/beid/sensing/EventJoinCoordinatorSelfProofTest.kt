package org.levarac.beid.sensing

import java.util.UUID
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * `EventJoinCoordinator` session-lifecycle wiring for self-proof — mirrors
 * iOS's `SensingCoordinatorSelfProofTests`
 * (`ios/BeidTests/SelfProofTests.swift`). Self-proof is signed once per
 * event, at session end, gated on the session having actually reached
 * `Recording` (a "Proof" existing) and an ENIN window having been observed
 * — never mid-session.
 *
 * `leaveEvent()` is part of the shared `EventJoinSession` UI-facing
 * interface (`Unit` return — out of scope to change here), so these tests
 * observe results through [SelfProofRecordStore] rather than a return
 * value, unlike iOS's `@discardableResult stopSensing() -> SelfProofRecord?`.
 *
 * Wired to [EventJoinCoordinator.leaveEvent] (the Account screen's real
 * "Leave Event" action, beid#126) as the primary trigger, and to
 * [EventJoinCoordinator.dispose] as a teardown safety net — see this task's
 * handoff for why iOS's identically-named `leaveEvent()` is NOT the
 * analogous hook (it is a different, narrower, pre-auto-discovery
 * mechanism on iOS) and why `dispose()` is the literal counterpart of
 * iOS's `stopSensing()`/`endSensing(stopEngine:)` instead.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorSelfProofTest {
    @Test
    fun leaveEventWithNoSessionEverStartedProducesNoSelfProof() = runTest {
        val store = SelfProofRecordStore(newTempRecordFile("self-proofs"))
        val coordinator = coordinator(FakeEventJoinEngine(), FakeSensingCryptography(), selfProofRecordStore = store)

        coordinator.leaveEvent()

        assertTrue(store.records.isEmpty(), "no Proof, no ENIN window — nothing to attest")
    }

    @Test
    fun leaveEventProducesASelfProofOnlyAfterRecordingBegan() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val store = SelfProofRecordStore(newTempRecordFile("self-proofs"))
        val coordinator = coordinator(engine, FakeSensingCryptography(), selfProofRecordStore = store, nearbyRegistry = registry)

        joinPromotedVectorEvent(coordinator, engine, registry)
        confirmRecording(engine)
        require(coordinator.state.value is EventJoinUiState.Sensing) { "expected Sensing state" }

        coordinator.leaveEvent()

        val record = store.records.singleOrNull()
        requireNotNull(record) { "expected exactly one self-proof record" }
        assertEquals(NearbyEventPromotionFixture.EVENT_ID_HEX, record.eventCode)
        assertTrue(record.eninStart <= record.eninEnd)
        assertTrue(record.eventSigningPublicKeyHex.isNotEmpty())
        assertTrue(record.ownerPublicKeyHex.isNotEmpty())
        assertTrue(record.signatureRHex.isNotEmpty())
        assertEquals(EventJoinUiState.Idle, coordinator.state.value, "session ended")
    }

    @Test
    fun disposeAfterLeaveEventDoesNotProduceASecondSelfProof() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val store = SelfProofRecordStore(newTempRecordFile("self-proofs"))
        val coordinator = coordinator(engine, FakeSensingCryptography(), selfProofRecordStore = store, nearbyRegistry = registry)

        joinPromotedVectorEvent(coordinator, engine, registry)
        confirmRecording(engine)
        coordinator.leaveEvent()
        assertEquals(1, store.records.size)

        coordinator.dispose()

        assertEquals(1, store.records.size, "session state was already cleared by leaveEvent()")
    }

    @Test
    fun disposeAloneProducesASelfProofWhenLeaveEventWasNeverCalled() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val store = SelfProofRecordStore(newTempRecordFile("self-proofs"))
        val coordinator = coordinator(engine, FakeSensingCryptography(), selfProofRecordStore = store, nearbyRegistry = registry)

        joinPromotedVectorEvent(coordinator, engine, registry)
        confirmRecording(engine)

        coordinator.dispose()

        assertEquals(1, store.records.size, "dispose() is the teardown safety net iOS's stopSensing() maps to")
    }

    @Test
    fun eventFoundWithoutReachingRecordingProducesNoSelfProof() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val store = SelfProofRecordStore(newTempRecordFile("self-proofs"))
        val coordinator = coordinator(engine, FakeSensingCryptography(), selfProofRecordStore = store, nearbyRegistry = registry)

        joinPromotedVectorEvent(coordinator, engine, registry)
        // Only one detection: below defaultEventConfirmThreshold (3), never reaches Recording.
        engine.emitDetection(enin = 1, rpid = "aa", detectedDisplayId = "device-1")

        coordinator.leaveEvent()

        assertTrue(store.records.isEmpty(), "EventFound/Sensing never produced a Proof")
    }

    @Test
    fun onProofSignatureStateChangedFiresFromLeaveEventWithNoPriorBinding() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, FakeSensingCryptography(), nearbyRegistry = registry)
        val calls = mutableListOf<Triple<UUID, Boolean, Boolean>>()
        coordinator.onProofSignatureStateChanged = { proofId, hasSelfProof, hasBinding -> calls += Triple(proofId, hasSelfProof, hasBinding) }

        joinPromotedVectorEvent(coordinator, engine, registry)
        confirmRecording(engine)
        coordinator.leaveEvent()

        val (_, hasSelfProof, hasBinding) = calls.single()
        assertTrue(hasSelfProof, "the self-proof this call just persisted")
        assertTrue(!hasBinding, "no binding was ever attempted this session")
    }

    @Test
    fun onProofSignatureStateChangedFiresFromLeaveEventWithBindingAlreadyPresent() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, FakeSensingCryptography(), nearbyRegistry = registry)
        val calls = mutableListOf<Triple<UUID, Boolean, Boolean>>()
        coordinator.onProofSignatureStateChanged = { proofId, hasSelfProof, hasBinding -> calls += Triple(proofId, hasSelfProof, hasBinding) }
        val walletAddress = "0x14791697260e4c9a71f18484c9f997b308e59325"

        joinPromotedVectorEvent(coordinator, engine, registry)
        confirmRecording(engine)
        coordinator.beginBinding(walletAddress, chainId = 1)
        coordinator.completeBinding(walletAddress, walletSignatureHex = "0x" + "0a".repeat(65))
        coordinator.leaveEvent()

        assertEquals(2, calls.size, "one from completeBinding, one from leaveEvent's finalizeSelfProofIfNeeded")
        val (_, hasSelfProofAtBindingTime, hasBindingAtBindingTime) = calls[0]
        assertTrue(!hasSelfProofAtBindingTime, "no self-proof exists yet when completeBinding fires")
        assertTrue(hasBindingAtBindingTime)
        val (_, hasSelfProofAtLeaveTime, hasBindingAtLeaveTime) = calls[1]
        assertTrue(hasSelfProofAtLeaveTime)
        assertTrue(hasBindingAtLeaveTime, "the binding recorded earlier this session must still be reported")
    }

    /**
     * Pins beid#650: leave ends the recording session but not discovery.
     * The scan pre-join discovery started is never stopped, a newly seen
     * event still becomes a joinable card that can be joined again, and the
     * left session's self-proof is persisted exactly once.
     */
    @Test
    fun leaveEventEndsTheRecordingSessionButNotDiscovery() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val store = SelfProofRecordStore(newTempRecordFile("self-proofs"))
        val coordinator = coordinator(engine, FakeSensingCryptography(), selfProofRecordStore = store, nearbyRegistry = registry)
        coordinator.requestBluetoothPermission {}

        joinPromotedVectorEvent(coordinator, engine, registry)
        confirmRecording(engine)
        coordinator.leaveEvent()

        assertEquals(0, engine.stopScanCalls, "leave must not stop the scan")
        assertTrue(engine.engineState.isScanning, "discovery is still live after leave")
        val record = requireNotNull(store.records.singleOrNull()) { "expected exactly one self-proof record after leave" }
        assertEquals(NearbyEventPromotionFixture.EVENT_ID_HEX, record.eventCode)

        // No unrelated hint in between: the fake registry holds one pending completion.
        promoteVectorCandidate(engine, registry)
        val card = coordinator.nearbyEventCards.value.singleOrNull {
            it.eventCodeHashHex == NearbyEventPromotionFixture.EVENT_CODE_HASH
        }
        requireNotNull(card) { "the event seen after leave must surface as a card" }
        assertEquals(NearbyEventPromotionFixture.EVENT_ID_HEX, card.eventIdHex, "the card must be joinable")

        coordinator.joinNearbyEvent(NearbyEventPromotionFixture.EVENT_CODE_HASH)
        runCurrent()

        assertTrue(coordinator.state.value is EventJoinUiState.Sensing, "the card joined again after leave")
        assertEquals(1, store.records.size, "re-joining alone must not persist a second self-proof")
        assertEquals(record, store.records.single())
        assertEquals(0, engine.stopScanCalls)
        assertTrue(engine.engineState.isScanning)
    }

    private fun confirmRecording(engine: FakeEventJoinEngine) {
        engine.emitDetection(enin = 1, rpid = "aa", detectedDisplayId = "device-1")
        engine.emitDetection(enin = 2, rpid = "bb", detectedDisplayId = "device-2")
        engine.emitDetection(enin = 3, rpid = "cc", detectedDisplayId = "device-3")
    }

    private fun TestScope.coordinator(
        engine: FakeEventJoinEngine,
        cryptography: FakeSensingCryptography,
        selfProofRecordStore: SelfProofRecordStore = SelfProofRecordStore(newTempRecordFile("self-proofs")),
        bindingRecordStore: BindingRecordStore = BindingRecordStore(newTempRecordFile("binding-records")),
        nearbyRegistry: FakeNearbyEventRegistry = FakeNearbyEventRegistry(),
    ): EventJoinCoordinator = EventJoinCoordinator(
        engine = engine,
        nearbyRegistry = nearbyRegistry,
        nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS + testScheduler.currentTime },
        coroutineScope = backgroundScope,
        sensingCryptography = cryptography,
        selfProofRecordStore = selfProofRecordStore,
        bindingRecordStore = bindingRecordStore,
    )
}

package org.levarac.beid.sensing

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
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
        val store = SelfProofRecordStore(newTempRecordFile("self-proofs"))
        val coordinator = coordinator(engine, FakeSensingCryptography(), selfProofRecordStore = store)

        coordinator.joinEvent("SELF-PROOF-EVENT")
        confirmRecording(engine)
        require(coordinator.state.value is EventJoinUiState.Sensing) { "expected Sensing state" }

        coordinator.leaveEvent()

        val record = store.records.singleOrNull()
        requireNotNull(record) { "expected exactly one self-proof record" }
        assertEquals("SELF-PROOF-EVENT", record.eventCode)
        assertTrue(record.eninStart <= record.eninEnd)
        assertTrue(record.eventSigningPublicKeyHex.isNotEmpty())
        assertTrue(record.ownerPublicKeyHex.isNotEmpty())
        assertTrue(record.signatureRHex.isNotEmpty())
        assertEquals(EventJoinUiState.Idle, coordinator.state.value, "session ended")
    }

    @Test
    fun disposeAfterLeaveEventDoesNotProduceASecondSelfProof() = runTest {
        val engine = FakeEventJoinEngine()
        val store = SelfProofRecordStore(newTempRecordFile("self-proofs"))
        val coordinator = coordinator(engine, FakeSensingCryptography(), selfProofRecordStore = store)

        coordinator.joinEvent("SELF-PROOF-EVENT")
        confirmRecording(engine)
        coordinator.leaveEvent()
        assertEquals(1, store.records.size)

        coordinator.dispose()

        assertEquals(1, store.records.size, "session state was already cleared by leaveEvent()")
    }

    @Test
    fun disposeAloneProducesASelfProofWhenLeaveEventWasNeverCalled() = runTest {
        val engine = FakeEventJoinEngine()
        val store = SelfProofRecordStore(newTempRecordFile("self-proofs"))
        val coordinator = coordinator(engine, FakeSensingCryptography(), selfProofRecordStore = store)

        coordinator.joinEvent("SELF-PROOF-EVENT")
        confirmRecording(engine)

        coordinator.dispose()

        assertEquals(1, store.records.size, "dispose() is the teardown safety net iOS's stopSensing() maps to")
    }

    @Test
    fun eventFoundWithoutReachingRecordingProducesNoSelfProof() = runTest {
        val engine = FakeEventJoinEngine()
        val store = SelfProofRecordStore(newTempRecordFile("self-proofs"))
        val coordinator = coordinator(engine, FakeSensingCryptography(), selfProofRecordStore = store)

        coordinator.joinEvent("SELF-PROOF-EVENT")
        // Only one detection: below defaultEventConfirmThreshold (3), never reaches Recording.
        engine.emitDetection(enin = 1, rpid = "aa", detectedDisplayId = "device-1")

        coordinator.leaveEvent()

        assertTrue(store.records.isEmpty(), "EventFound/Sensing never produced a Proof")
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
    ): EventJoinCoordinator = EventJoinCoordinator(
        engine = engine,
        nowEpochMillis = { testScheduler.currentTime },
        coroutineScope = backgroundScope,
        sensingCryptography = cryptography,
        selfProofRecordStore = selfProofRecordStore,
        bindingRecordStore = bindingRecordStore,
    )
}

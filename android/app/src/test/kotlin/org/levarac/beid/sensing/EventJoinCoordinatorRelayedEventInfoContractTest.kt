package org.levarac.beid.sensing

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.levarac.barnard.BarnardB005EnvelopeV2
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.wireProofRecording
import org.levarac.parallax.discovery.NearbyEventReceiverState
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Contract test for levarac/dispatch#50's pre-delivery criterion: a device
 * that never heard the venue source receives the event info through a relay,
 * joins, and ends up with an observation record.
 *
 * ## What makes the input relayed
 *
 * Spec 134 re-broadcast copies the signed envelope byte for byte and changes
 * only the container's hop count. So the relayed copy here is barnard's own
 * `encodeContainer(relayHopCount = 1, …)` around the same conformance-vector
 * envelope the hop-zero fixture carries: genuinely signed, genuinely hop 1,
 * and emitted from a relayer peripheral. No hop-zero container is ever
 * emitted, which is what "never saw the source" means at this seam.
 *
 * ## What it drives, and what it does not
 *
 * The radio is [FakeEventJoinEngine], so the envelope enters through the
 * coordinator's real `onEvent` dispatch; barnard's real `verify` produces the
 * receipt; the shared reducer promotes the candidate against the registry
 * answer; the join goes through the real capability gate; detections cross
 * the confirm threshold; and the record reaches both stores the app reads —
 * the #121 records list (via the production `wireProofRecording`) and the
 * self-proof store at session end.
 *
 * Android has no submission queue for these records today (AGENTS.md: the
 * unsent-window ledger has neither producer nor consumer on Android), so
 * "queued for submission" is asserted on iOS only. Real-radio relay between
 * physical devices is the ship gate's job (levarac/dispatch#62), not this
 * test's.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorRelayedEventInfoContractTest {
    @Test
    fun relayedEventInfoFromAParticipantReachesJoinAndARecord() = runTest {
        val relayedContainer = requireNotNull(
            BarnardB005EnvelopeV2.encodeContainer(1, NearbyEventPromotionFixture.ENVELOPE),
        )
        // Guards the premise: if this ever stopped being a verifiable hop-1
        // copy, the test below would silently become the hop-zero test.
        val verified = assertNotNull(
            BarnardB005EnvelopeV2.verify(relayedContainer, NearbyEventPromotionFixture.ENIN),
        )
        assertEquals(1, verified.relayHopCount)
        assertFalse(relayedContainer.contentEquals(NearbyEventPromotionFixture.CONTAINER))

        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val proofRecordStore = ProofRecordStore(newTempRecordFile("proof-records"))
        val selfProofRecordStore = SelfProofRecordStore(newTempRecordFile("self-proofs"))
        val coordinator = coordinator(engine, registry, selfProofRecordStore)
        wireProofRecording(coordinator, ProofRecordingBridge(proofRecordStore))

        promoteVectorCandidate(
            engine,
            registry,
            container = relayedContainer,
            peripheralId = RELAYER_PERIPHERAL_ID,
        )

        val candidate = assertNotNull(coordinator.nearbyEventCandidates.value.candidateAt(0))
        assertEquals(NearbyEventReceiverState.REGISTRY_VERIFIED, candidate.receiverState)
        assertEquals(RELAYER_PERIPHERAL_ID, candidate.sourceAt(0)?.peripheralId)
        assertEquals(null, candidate.sourceAt(1), "only the relayer was ever heard")
        assertContentEquals(relayedContainer, candidate.rawEnvelopeContainer)

        coordinator.joinNearbyEvent(NearbyEventPromotionFixture.EVENT_CODE_HASH)
        testScheduler.runCurrent()

        assertEquals(1, engine.joinEventCalls, "the relayed candidate was admitted exactly once")
        assertEquals(NearbyEventPromotionFixture.EVENT_ID_HEX, coordinator.relayGateJoinedEventIdHexForTesting)

        engine.emitDetection(enin = 1, rpid = "aa", detectedDisplayId = "device-1")
        engine.emitDetection(enin = 2, rpid = "bb", detectedDisplayId = "device-2")
        engine.emitDetection(enin = 3, rpid = "cc", detectedDisplayId = "device-3")

        val listed = assertNotNull(proofRecordStore.records.singleOrNull(), "one record in the records list")
        assertEquals(NearbyEventPromotionFixture.EVENT_ID_HEX, listed.eventCode)

        coordinator.leaveEvent()

        val selfProof = assertNotNull(selfProofRecordStore.records.singleOrNull(), "one self-proof")
        assertEquals(NearbyEventPromotionFixture.EVENT_ID_HEX, selfProof.eventCode)
        assertTrue(assertNotNull(proofRecordStore.recordForId(listed.id)).hasSelfProof)
    }

    private fun TestScope.coordinator(
        engine: FakeEventJoinEngine,
        registry: FakeNearbyEventRegistry,
        selfProofRecordStore: SelfProofRecordStore,
    ): EventJoinCoordinator = EventJoinCoordinator(
        engine = engine,
        nearbyRegistry = registry,
        nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS + testScheduler.currentTime },
        coroutineScope = backgroundScope,
        sensingCryptography = FakeSensingCryptography(),
        selfProofRecordStore = selfProofRecordStore,
        bindingRecordStore = BindingRecordStore(newTempRecordFile("binding-records")),
    )

    private companion object {
        const val RELAYER_PERIPHERAL_ID = "peripheral-relaying-participant"
    }
}

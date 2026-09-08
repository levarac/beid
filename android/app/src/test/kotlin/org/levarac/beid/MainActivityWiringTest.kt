package org.levarac.beid

import java.io.File
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.sensing.EventJoinCoordinator
import org.levarac.beid.sensing.FakeEventJoinEngine
import org.levarac.beid.sensing.FakeNearbyEventRegistry
import org.levarac.beid.sensing.NearbyEventPromotionFixture
import org.levarac.beid.sensing.joinPromotedVectorEvent
import org.levarac.beid.sensing.FakeSensingCryptography
import org.levarac.beid.sensing.ProofRecordingBridge
import org.levarac.beid.sensing.newTempRecordFile

/**
 * Proves [wireProofRecording] itself — the seam `MainActivity.onCreate()`
 * uses to connect [EventJoinCoordinator]'s three gh#235 callback properties
 * to a [ProofRecordingBridge] — rather than re-proving [ProofRecordingBridge]
 * (already covered standalone by `ProofRecordingBridgeTest`) or
 * [EventJoinCoordinator]'s own callback-firing behavior (already covered by
 * `EventJoinCoordinatorSelfProofTest`/`EventJoinCoordinatorBindingTest`).
 *
 * **What this does not cover**: `MainActivity.onCreate()`'s own construction
 * of the real, `Activity`-backed [EventJoinCoordinator]/[ProofRecordStore]/
 * [ProofRecordingBridge] instances and the `filesDir`-derived default file
 * paths. This repository's existing tests never construct
 * [EventJoinCoordinator] through its `Activity` secondary constructor under
 * Robolectric — every coordinator test in this codebase (see
 * `EventJoinCoordinatorSelfProofTest`/`EventJoinCoordinatorBindingTest`)
 * uses the `internal` test constructor with [FakeEventJoinEngine]/
 * [FakeSensingCryptography] instead, because the real constructor pulls in
 * a live `BarnardEventJoinEngine`, Keystore-backed
 * `BarnardSensingCryptography`, and Bluetooth permission plumbing that
 * Robolectric does not stand in for here. This test follows that same
 * established pattern rather than introducing a new one, which means it
 * proves the *wiring function* is correct in isolation but does not prove
 * `onCreate()` actually calls it with the real objects — that remains
 * verified by reading `MainActivity.kt` directly (see the single call site)
 * and by `assembleDebug` succeeding (the real `Activity` constructor path
 * still has to compile and link against gh#235's actual property types).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MainActivityWiringTest {
    @Test
    fun wiringConnectsAllThreeCallbackPropertiesToTheStore() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, nearbyRegistry = registry)
        val proofRecordStore = ProofRecordStore(tempProofRecordFile())
        val bridge = ProofRecordingBridge(proofRecordStore)

        wireProofRecording(coordinator, bridge)

        assertNotNull(coordinator.onProofCollected, "onProofCollected must be assigned")
        assertNotNull(coordinator.onPeersVerifiedChanged, "onPeersVerifiedChanged must be assigned")
        assertNotNull(coordinator.onProofSignatureStateChanged, "onProofSignatureStateChanged must be assigned")
    }

    @Test
    fun onProofCollectedInvocationReachesTheStore() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, nearbyRegistry = registry)
        val proofRecordStore = ProofRecordStore(tempProofRecordFile())
        val bridge = ProofRecordingBridge(proofRecordStore)
        wireProofRecording(coordinator, bridge)

        // A real EventJoinCoordinator session, not a direct bridge call --
        // this is what distinguishes "the wiring works" from "the bridge
        // works" (already proven by ProofRecordingBridgeTest on its own).
        joinPromotedVectorEvent(coordinator, engine, registry)
        confirmRecording(engine)

        assertEquals(1, proofRecordStore.records.size, "onProofCollected must have reached the store via the wiring")
        val record = proofRecordStore.records.single()
        assertEquals(NearbyEventPromotionFixture.EVENT_ID_HEX, record.eventCode)
        assertTrue(record.peersVerified > 0)
    }

    @Test
    fun onPeersVerifiedChangedInvocationReachesTheStore() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, nearbyRegistry = registry)
        val proofRecordStore = ProofRecordStore(tempProofRecordFile())
        val bridge = ProofRecordingBridge(proofRecordStore)
        wireProofRecording(coordinator, bridge)
        joinPromotedVectorEvent(coordinator, engine, registry)
        confirmRecording(engine)
        val initialCount = proofRecordStore.records.single().peersVerified

        engine.emitDetection(enin = 4, rpid = "dd", detectedDisplayId = "device-4")

        val updatedCount = proofRecordStore.records.single().peersVerified
        assertTrue(updatedCount > initialCount, "onPeersVerifiedChanged must have reached the store via the wiring")
    }

    @Test
    fun onProofSignatureStateChangedInvocationReachesTheStore() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, nearbyRegistry = registry)
        val proofRecordStore = ProofRecordStore(tempProofRecordFile())
        val bridge = ProofRecordingBridge(proofRecordStore)
        wireProofRecording(coordinator, bridge)
        joinPromotedVectorEvent(coordinator, engine, registry)
        confirmRecording(engine)

        coordinator.leaveEvent() // finalizeSelfProofIfNeeded() fires onProofSignatureStateChanged

        val record = proofRecordStore.records.single()
        assertTrue(record.hasSelfProof, "onProofSignatureStateChanged must have reached the store via the wiring")
    }

    private fun confirmRecording(engine: FakeEventJoinEngine) {
        engine.emitDetection(enin = 1, rpid = "aa", detectedDisplayId = "device-1")
        engine.emitDetection(enin = 2, rpid = "bb", detectedDisplayId = "device-2")
        engine.emitDetection(enin = 3, rpid = "cc", detectedDisplayId = "device-3")
    }

    private fun tempProofRecordFile(): File = newTempRecordFile("proof-records")

    private fun TestScope.coordinator(
        engine: FakeEventJoinEngine,
        selfProofRecordStore: SelfProofRecordStore = SelfProofRecordStore(newTempRecordFile("self-proofs")),
        bindingRecordStore: BindingRecordStore = BindingRecordStore(newTempRecordFile("binding-records")),
        nearbyRegistry: FakeNearbyEventRegistry = FakeNearbyEventRegistry(),
    ): EventJoinCoordinator = EventJoinCoordinator(
        engine = engine,
        nearbyRegistry = nearbyRegistry,
        nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS + testScheduler.currentTime },
        coroutineScope = backgroundScope,
        sensingCryptography = FakeSensingCryptography(),
        selfProofRecordStore = selfProofRecordStore,
        bindingRecordStore = bindingRecordStore,
    )
}

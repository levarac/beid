package org.levarac.beid.sensing

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.persistence.SessionAggregateSnapshotStore
import org.levarac.beid.persistence.SessionCheckpointStore
import org.levarac.beid.wireProofRecording
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorCheckpointInvariantsTest {
    @Test
    fun suspendedSelfProofStoreStillPersistsAggregateAndRetainsCheckpointUntilReadBack() = runTest {
        val directory = Files.createTempDirectory("checkpoint-suspended-proof-store").toFile()
        val proofFile = SelfProofRecordStore.defaultFile(directory)
        proofFile.writeText("corrupt self-proofs")
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val live = coordinator(directory, engine, registry)
        val records = ProofRecordStore(ProofRecordStore.defaultFile(directory))
        wireProofRecording(live, ProofRecordingBridge(records))
        joinPromotedVectorEvent(live, engine, registry)
        repeat(3) { engine.emitDetection(enin = 7, rpid = "peer-$it", detectedDisplayId = "peer-$it") }
        live.checkpointSession()
        val checkpoints = SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory))
        val proofId = checkpoints.proofIds().single()
        live.leaveEvent()
        live.dispose()
        assertEquals(3, SessionAggregateSnapshotStore(SessionAggregateSnapshotStore.defaultFile(directory))
            .snapshot(proofId)?.observationCount, "aggregate persistence must precede the suspended self-proof store")
        assertEquals("corrupt self-proofs", proofFile.readText())
        assertTrue(SelfProofRecordStore(proofFile).records.isEmpty())
        assertEquals(listOf(proofId), checkpoints.proofIds(), "a no-op add is not a durable signed record")
        assertFalse(records.recordsFlow.value.single().hasSelfProof)

        assertTrue(proofFile.delete())
        val recovered = coordinator(directory)
        try {
            recovered.drainPendingSubmissionsOnForeground()
            runCurrent()
            assertEquals(proofId, SelfProofRecordStore(proofFile).records.single().proofId)
            assertTrue(checkpoints.proofIds().isEmpty(), "read-back plus a saved aggregate permits removal")
        } finally {
            recovered.dispose()
        }
    }

    private fun TestScope.coordinator(
        directory: File,
        engine: FakeEventJoinEngine = FakeEventJoinEngine(),
        registry: FakeNearbyEventRegistry = FakeNearbyEventRegistry(),
        cryptography: FakeSensingCryptography = FakeSensingCryptography(),
    ) = EventJoinCoordinator(
        engine = engine,
        nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS + testScheduler.currentTime },
        coroutineScope = backgroundScope,
        nearbyRegistry = registry,
        sensingCryptography = cryptography,
        selfProofRecordStore = SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)),
        bindingRecordStore = BindingRecordStore(BindingRecordStore.defaultFile(directory)),
        ledgerFilesDir = directory,
        checkpointDispatcher = StandardTestDispatcher(testScheduler),
    )
}

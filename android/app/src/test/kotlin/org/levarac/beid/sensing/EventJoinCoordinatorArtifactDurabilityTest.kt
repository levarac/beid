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
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorArtifactDurabilityTest {
    @Test
    fun corruptProofRowsKeepRecoveryInput() = suspendedProofRowsKeepCheckpoint("corrupt proof rows", true)

    @Test
    fun unsupportedProofRowsKeepRecoveryInput() =
        suspendedProofRowsKeepCheckpoint("""{"schemaVersion":99,"records":[]}""", true)

    @Test
    fun corruptProofRowsKeepFinalizationInput() = suspendedProofRowsKeepCheckpoint("corrupt proof rows", false)

    @Test
    fun unsupportedProofRowsKeepFinalizationInput() =
        suspendedProofRowsKeepCheckpoint("""{"schemaVersion":99,"records":[]}""", false)

    private fun suspendedProofRowsKeepCheckpoint(unreadable: String, recover: Boolean) = runTest {
        val directory = Files.createTempDirectory("checkpoint-proof-row-durability").toFile()
        val file = ProofRecordStore.defaultFile(directory)
        file.writeText(unreadable)
        val owner = SessionCheckpointRuntimeOwner()
        val records = owner.proofRecordStore(file)
        assertTrue(records.isPersistenceSuspended)
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val cryptography = if (recover) FakeSensingCryptography(selfProofSignatureResult = null) else FakeSensingCryptography()
        val live = coordinator(directory, owner, engine, registry, cryptography)
        wireProofRecording(live, ProofRecordingBridge(records))
        joinPromotedVectorEvent(live, engine, registry)
        repeat(3) { engine.emitDetection(enin = 7, rpid = "peer-$it", detectedDisplayId = "peer-$it") }
        live.checkpointSession()
        val checkpoints = SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory))
        val proofId = checkpoints.proofIds().single()
        live.leaveEvent()
        val recovery = if (recover) coordinator(directory, owner).also {
            wireProofRecording(it, ProofRecordingBridge(records))
            it.drainPendingSubmissionsOnForeground()
            runCurrent()
        } else null
        try {
            assertEquals(proofId, SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)).records.single().proofId)
            assertEquals(3, SessionAggregateSnapshotStore(SessionAggregateSnapshotStore.defaultFile(directory))
                .snapshot(proofId)?.observationCount)
            assertEquals(unreadable, file.readText())
            assertEquals(listOf(proofId), checkpoints.proofIds(), "a suspended Records store must retain its reconstruction input")
        } finally {
            live.dispose()
            recovery?.dispose()
        }

        // A repaired file is reopened by a fresh process owner, then the row is rebuilt.
        assertTrue(file.delete())
        val repairedOwner = SessionCheckpointRuntimeOwner()
        val repairedRecords = repairedOwner.proofRecordStore(file)
        val repaired = coordinator(directory, repairedOwner)
        wireProofRecording(repaired, ProofRecordingBridge(repairedRecords))
        try {
            repeat(2) {
                repaired.drainPendingSubmissionsOnForeground()
                runCurrent()
            }
            val row = assertNotNull(ProofRecordStore(file).recordForId(proofId))
            assertEquals(NearbyEventPromotionFixture.EVENT_ID_HEX, row.eventCode)
            assertEquals(3, row.peersVerified)
            assertTrue(row.hasSelfProof)
            assertEquals(1, repairedRecords.records.size)
            assertTrue(checkpoints.proofIds().isEmpty(), "all artifacts read back after repair")
        } finally {
            repaired.dispose()
        }
    }

    @Test
    fun failedSelfProofReadBackKeepsCheckpoint() = failedArtifactReadBackKeepsCheckpoint("self-proof")

    @Test
    fun failedAggregateReadBackKeepsCheckpoint() = failedArtifactReadBackKeepsCheckpoint("aggregate")

    @Test
    fun failedProofRowReadBackKeepsCheckpoint() = failedArtifactReadBackKeepsCheckpoint("proof-row")

    private fun failedArtifactReadBackKeepsCheckpoint(artifact: String) = runTest {
        val directory = Files.createTempDirectory("checkpoint-artifact-readback").toFile()
        val owner = SessionCheckpointRuntimeOwner()
        val records = owner.proofRecordStore(ProofRecordStore.defaultFile(directory))
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val live = coordinator(directory, owner, engine, registry, FakeSensingCryptography(selfProofSignatureResult = null))
        wireProofRecording(live, ProofRecordingBridge(records))
        joinPromotedVectorEvent(live, engine, registry)
        repeat(3) { engine.emitDetection(enin = 7, rpid = "peer-$it", detectedDisplayId = "peer-$it") }
        live.leaveEvent()
        live.dispose()
        val checkpoints = SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory))
        val proofId = checkpoints.proofIds().single()
        val file = when (artifact) {
            "self-proof" -> SelfProofRecordStore.defaultFile(directory)
            "aggregate" -> SessionAggregateSnapshotStore.defaultFile(directory)
            else -> ProofRecordStore.defaultFile(directory)
        }
        val cryptography = FakeSensingCryptography()
        val recovery = coordinator(directory, owner, cryptography = cryptography)
        wireProofRecording(recovery, ProofRecordingBridge(records))
        val update = assertNotNull(recovery.onProofSignatureStateChanged)
        var validBytes: ByteArray? = null
        recovery.onProofSignatureStateChanged = { id, selfProof, binding ->
            update(id, selfProof, binding)
            validBytes = file.readBytes()
            file.writeText("unreadable after artifact persistence")
        }
        try {
            recovery.drainPendingSubmissionsOnForeground()
            runCurrent()
            assertEquals(listOf(proofId), checkpoints.proofIds(), "$artifact must read back before recovery input is removed")
            recovery.onProofSignatureStateChanged = update
            file.writeBytes(assertNotNull(validBytes))
            recovery.drainPendingSubmissionsOnForeground()
            runCurrent()
            assertTrue(checkpoints.proofIds().isEmpty())
            assertEquals(1, cryptography.calls.count { it is FakeSensingCryptography.Call.SignSelfProof })
            assertTrue(ProofRecordStore(ProofRecordStore.defaultFile(directory)).recordForId(proofId)?.hasSelfProof == true)
        } finally {
            recovery.dispose()
        }
    }

    private fun TestScope.coordinator(
        directory: File,
        owner: SessionCheckpointRuntimeOwner,
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
        checkpointRuntimeOwner = owner,
    )
}

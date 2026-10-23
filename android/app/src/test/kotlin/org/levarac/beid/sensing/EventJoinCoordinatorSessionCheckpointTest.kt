package org.levarac.beid.sensing

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
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
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorSessionCheckpointTest {
    @Test
    fun recordingCheckpointRecoversTheSameRecordAndFinalizesOnlyOnce() = runTest {
        val directory = Files.createTempDirectory("session-checkpoint").toFile()
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val first = coordinator(directory, engine, registry)
        val records = ProofRecordStore(ProofRecordStore.defaultFile(directory))
        wireProofRecording(first, ProofRecordingBridge(records))
        joinPromotedVectorEvent(first, engine, registry)
        engine.emitDetection(enin = 7, rpid = "aa", detectedDisplayId = "device-1")
        engine.emitDetection(enin = 7, rpid = "bb", detectedDisplayId = "device-2")
        engine.emitDetection(enin = 7, rpid = "cc", detectedDisplayId = "device-3")
        runCurrent()
        advanceTimeBy(1_000)
        runCurrent()
        assertIs<ScanPhase.Recording>((first.state.value as EventJoinUiState.Sensing).phase)
        val proofId = records.records.single().id
        assertTrue(SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)).records.isEmpty())

        // No leave/dispose: the process disappeared after its recording checkpoint.
        engine.onEvent = null
        val recovered = coordinator(directory)
        val reloadedRecords = ProofRecordStore(ProofRecordStore.defaultFile(directory))
        wireProofRecording(recovered, ProofRecordingBridge(reloadedRecords))
        recovered.drainPendingSubmissionsOnForeground()
        runCurrent()

        val selfProof = assertNotNull(
            SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)).records.singleOrNull(),
            "a new coordinator must recover the checkpoint without graceful teardown",
        )
        assertEquals(proofId, selfProof.proofId)
        assertEquals(NearbyEventPromotionFixture.EVENT_ID_HEX, selfProof.eventCode)
        assertEquals(7L, selfProof.eninStart)
        assertEquals(7L, selfProof.eninEnd)
        assertTrue(reloadedRecords.records.single().hasSelfProof)
        val aggregate = SessionAggregateSnapshotStore(
            SessionAggregateSnapshotStore.defaultFile(directory),
        ).snapshot(proofId)
        assertEquals(3, aggregate?.observationCount)
        assertEquals(3, aggregate?.deviceCount)
        assertEquals(1, aggregate?.windowCount)

        recovered.drainPendingSubmissionsOnForeground()
        recovered.leaveEvent()
        recovered.dispose()
        val relaunched = coordinator(directory)
        relaunched.drainPendingSubmissionsOnForeground()
        relaunched.leaveEvent()
        relaunched.dispose()
        assertEquals(listOf(selfProof), SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)).records)
        assertEquals(1, ProofRecordStore(ProofRecordStore.defaultFile(directory)).records.size)
        assertEquals(1, SessionAggregateSnapshotStore(
            SessionAggregateSnapshotStore.defaultFile(directory),
        ).records.size)
    }

    @Test
    fun foregroundDoesNotSealRecordingAndCheckpointsKeepTheLatestEvidence() = runTest {
        val directory = Files.createTempDirectory("active-checkpoint").toFile()
        val engine = FakeEventJoinEngine()
        val first = recording(directory, engine)
        first.checkpointSession()
        first.drainPendingSubmissionsOnForeground()
        assertIs<ScanPhase.Recording>((first.state.value as EventJoinUiState.Sensing).phase)
        assertTrue(selfProofs(directory).records.isEmpty())

        engine.emitDetection(enin = 8, rpid = "dd", detectedDisplayId = "device-4")
        engine.emitDetection(enin = 8, rpid = "dd", detectedDisplayId = "device-4")
        first.checkpointSession()
        engine.onEvent = null
        val recovered = coordinator(directory)
        recovered.drainPendingSubmissionsOnForeground()
        val record = selfProofs(directory).records.single()
        assertEquals(7L, record.eninStart)
        assertEquals(8L, record.eninEnd)
        val aggregate = snapshots(directory).snapshot(record.proofId)
        assertEquals(5, aggregate?.observationCount, "preserve every shared observation, including repeated detections")
        assertEquals(4, aggregate?.deviceCount)
        assertEquals(2, aggregate?.windowCount)
        recovered.dispose()
    }

    @Test
    fun staleCheckpointAfterGracefulFinalizationDoesNotSignAgainOrReplaceTheFinalAggregate() = runTest {
        val directory = Files.createTempDirectory("stale-checkpoint").toFile()
        val engine = FakeEventJoinEngine()
        val first = recording(directory, engine)
        val checkpointFile = SessionCheckpointStore.defaultDirectory(directory).listFiles()!!.single()
        val earlierCheckpoint = checkpointFile.readBytes()
        engine.emitDetection(enin = 8, rpid = "dd", detectedDisplayId = "device-4")
        first.dispose()
        val record = selfProofs(directory).records.single()
        assertEquals(8L, record.eninEnd)

        // Model a crash between final-artifact persistence and checkpoint removal.
        checkpointFile.writeBytes(earlierCheckpoint)
        val cryptography = FakeSensingCryptography()
        val recovered = coordinator(directory, cryptography = cryptography)
        recovered.drainPendingSubmissionsOnForeground()
        recovered.drainPendingSubmissionsOnForeground()
        recovered.dispose()
        assertEquals(listOf(record), selfProofs(directory).records)
        assertTrue(cryptography.calls.none { it is FakeSensingCryptography.Call.SignSelfProof })
        assertEquals(4, snapshots(directory).snapshot(record.proofId)?.observationCount)
        assertTrue(SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory)).proofIds().isEmpty())
    }

    @Test
    fun finishedUnsignedRecordKeepsItsAggregateAndCheckpointForSignatureRetry() = runTest {
        val directory = Files.createTempDirectory("unsigned-finished-aggregate").toFile()
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val first = coordinator(directory, engine, registry, FakeSensingCryptography(selfProofSignatureResult = null))
        val records = ProofRecordStore(ProofRecordStore.defaultFile(directory))
        wireProofRecording(first, ProofRecordingBridge(records))
        joinPromotedVectorEvent(first, engine, registry)
        repeat(3) { engine.emitDetection(enin = 7, rpid = "peer-$it", detectedDisplayId = "device-$it") }
        val proofId = records.records.single().id

        first.leaveEvent()
        first.dispose()
        assertTrue(selfProofs(directory).records.isEmpty())
        assertEquals(listOf(proofId), SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory)).proofIds())
        val aggregate = assertNotNull(snapshots(directory).snapshot(proofId), "finished metrics must not depend on signing")
        assertEquals(3, aggregate.observationCount)
        assertEquals(3, aggregate.deviceCount)
        assertEquals(1, aggregate.windowCount)

        val recovered = coordinator(directory)
        wireProofRecording(recovered, ProofRecordingBridge(ProofRecordStore(ProofRecordStore.defaultFile(directory))))
        recovered.drainPendingSubmissionsOnForeground()
        recovered.drainPendingSubmissionsOnForeground()
        recovered.dispose()
        assertEquals(proofId, selfProofs(directory).records.single().proofId)
        assertEquals(1, ProofRecordStore(ProofRecordStore.defaultFile(directory)).records.size)
        assertEquals(3, snapshots(directory).snapshot(proofId)?.observationCount)
        assertTrue(SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory)).proofIds().isEmpty())
    }

    @Test
    fun failedSignatureKeepsTheCheckpointForTheNextCoordinator() = runTest {
        val directory = Files.createTempDirectory("unsigned-checkpoint").toFile()
        recording(directory)
        val unavailable = coordinator(directory, cryptography = FakeSensingCryptography(selfProofSignatureResult = null))
        unavailable.drainPendingSubmissionsOnForeground()
        unavailable.dispose()
        assertTrue(selfProofs(directory).records.isEmpty())
        assertEquals(1, SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory)).proofIds().size)

        val recovered = coordinator(directory)
        recovered.drainPendingSubmissionsOnForeground()
        recovered.dispose()
        val record = selfProofs(directory).records.single()
        assertEquals(3, snapshots(directory).snapshot(record.proofId)?.observationCount)
        assertTrue(SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory)).proofIds().isEmpty())
    }

    @Test
    fun failedAggregatePersistenceRetainsRecoveryInputWithoutDuplicatingTheSignedRecord() = runTest {
        val directory = Files.createTempDirectory("aggregate-checkpoint-retry").toFile()
        recording(directory)
        val aggregateFile = SessionAggregateSnapshotStore.defaultFile(directory)
        assertTrue(aggregateFile.mkdir(), "block the final aggregate store with a directory")
        val blocked = coordinator(directory)
        blocked.drainPendingSubmissionsOnForeground()
        blocked.dispose()
        val record = selfProofs(directory).records.single()
        assertEquals(1, SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory)).proofIds().size)

        assertTrue(aggregateFile.delete())
        val cryptography = FakeSensingCryptography()
        val recovered = coordinator(directory, cryptography = cryptography)
        recovered.drainPendingSubmissionsOnForeground()
        recovered.dispose()
        assertEquals(listOf(record), selfProofs(directory).records)
        assertTrue(cryptography.calls.none { it is FakeSensingCryptography.Call.SignSelfProof })
        assertEquals(3, snapshots(directory).snapshot(record.proofId)?.observationCount)
        assertTrue(SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory)).proofIds().isEmpty())
    }

    @Test
    fun unreadableCheckpointIsPreservedAndCanBeRetriedAfterRepair() = runTest {
        val directory = Files.createTempDirectory("corrupt-session-checkpoint").toFile()
        recording(directory)
        val file = SessionCheckpointStore.defaultDirectory(directory).listFiles()!!.single()
        val valid = file.readBytes()
        file.writeText("unreadable checkpoint")
        val recovered = coordinator(directory)
        recovered.drainPendingSubmissionsOnForeground()
        assertEquals("unreadable checkpoint", file.readText())
        assertTrue(selfProofs(directory).records.isEmpty())

        file.writeBytes(valid)
        recovered.drainPendingSubmissionsOnForeground()
        recovered.dispose()
        val record = selfProofs(directory).records.single()
        assertEquals(3, snapshots(directory).snapshot(record.proofId)?.observationCount)
        assertTrue(!file.exists())
    }

    @Test
    fun aSessionThatNeverReachedRecordingHasNoCheckpointToRecover() = runTest {
        val directory = Files.createTempDirectory("unconfirmed-checkpoint").toFile()
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val first = coordinator(directory, engine, registry)
        joinPromotedVectorEvent(first, engine, registry)
        engine.emitDetection(enin = 7, rpid = "aa", detectedDisplayId = "device-1")
        first.checkpointSession()
        first.dispose()
        val recovered = coordinator(directory)
        recovered.drainPendingSubmissionsOnForeground()
        recovered.dispose()
        assertTrue(selfProofs(directory).records.isEmpty())
        assertTrue(snapshots(directory).records.isEmpty())
        assertTrue(SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory)).proofIds().isEmpty())
    }

    private fun TestScope.recording(directory: File, engine: FakeEventJoinEngine = FakeEventJoinEngine()): EventJoinCoordinator {
        val registry = FakeNearbyEventRegistry()
        val first = coordinator(directory, engine, registry)
        wireProofRecording(first, ProofRecordingBridge(ProofRecordStore(ProofRecordStore.defaultFile(directory))))
        joinPromotedVectorEvent(first, engine, registry)
        engine.emitDetection(enin = 7, rpid = "aa", detectedDisplayId = "device-1")
        engine.emitDetection(enin = 7, rpid = "bb", detectedDisplayId = "device-2")
        engine.emitDetection(enin = 7, rpid = "cc", detectedDisplayId = "device-3")
        assertIs<ScanPhase.Recording>((first.state.value as EventJoinUiState.Sensing).phase)
        first.checkpointSession()
        return first
    }

    private fun selfProofs(directory: File) = SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory))
    private fun snapshots(directory: File) = SessionAggregateSnapshotStore(SessionAggregateSnapshotStore.defaultFile(directory))

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

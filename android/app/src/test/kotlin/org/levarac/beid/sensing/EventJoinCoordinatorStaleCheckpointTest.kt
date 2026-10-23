package org.levarac.beid.sensing

import java.io.File
import java.io.IOException
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
import org.levarac.beid.persistence.SessionCheckpoint
import org.levarac.beid.persistence.SessionCheckpointStore
import org.levarac.beid.wireProofRecording
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorStaleCheckpointTest {
    @Test
    fun failedFinalFlushUsesDurableCheckpointForAggregateAndRecoveredSignature() = runTest {
        val directory = Files.createTempDirectory("checkpoint-stale-unsigned").toFile()
        val checkpoints = SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory))
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        var failedWrites = 0
        val first = coordinator(directory, engine, registry, FakeSensingCryptography(selfProofSignatureResult = null)) {
            if (it.aggregate.observationCount == 4) {
                failedWrites++
                throw IOException("latest checkpoint write unavailable")
            }
            checkpoints.persist(it)
        }
        wireProofRecording(first, ProofRecordingBridge(ProofRecordStore(ProofRecordStore.defaultFile(directory))))
        joinPromotedVectorEvent(first, engine, registry)
        repeat(3) { engine.emitDetection(enin = 7, rpid = "peer-$it", detectedDisplayId = "peer-$it") }
        first.checkpointSession()
        val proofId = checkpoints.proofIds().single()
        engine.emitDetection(enin = 8, rpid = "four", detectedDisplayId = "four")
        first.leaveEvent()
        first.dispose()
        assertEquals(1, failedWrites, "the final latest write must really fail")
        assertEquals(3, checkpoints.load(proofId)?.aggregate?.observationCount)
        assertEquals(7L, checkpoints.load(proofId)?.eninEnd)
        val aggregateFile = SessionAggregateSnapshotStore.defaultFile(directory)
        val persistedAggregate = aggregateFile.readBytes()
        assertEquals(3, SessionAggregateSnapshotStore(aggregateFile).snapshot(proofId)?.observationCount)
        assertTrue(SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)).records.isEmpty())

        val cryptography = FakeSensingCryptography()
        val recovered = coordinator(directory, cryptography = cryptography)
        val records = ProcessSessionCheckpointRuntimeOwner.proofRecordStore(ProofRecordStore.defaultFile(directory))
        wireProofRecording(recovered, ProofRecordingBridge(records))
        try {
            repeat(2) {
                recovered.drainPendingSubmissionsOnForeground()
                runCurrent()
            }
            val signed = SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)).records.single()
            assertEquals(7L, signed.eninStart)
            assertEquals(7L, signed.eninEnd)
            assertEquals(1, cryptography.calls.count { it is FakeSensingCryptography.Call.SignSelfProof })
            assertTrue(persistedAggregate.contentEquals(aggregateFile.readBytes()), "the authoritative aggregate must win unchanged")
            assertEquals(3, SessionAggregateSnapshotStore(aggregateFile).snapshot(proofId)?.observationCount)
            assertTrue(checkpoints.proofIds().isEmpty(), "remove recovery input after durable artifacts")
            assertEquals(proofId, records.recordsFlow.value.single().id)
            assertTrue(records.recordsFlow.value.single().hasSelfProof)
        } finally {
            recovered.dispose()
        }
    }

    @Test
    fun failedFinalFlushWithIdenticalAggregateSignsOnlyTheDurableRange() = runTest {
        val directory = Files.createTempDirectory("checkpoint-equal-aggregate").toFile()
        val checkpoints = SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory))
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        var failedWrites = 0
        val live = coordinator(directory, engine, registry) {
            if (it.eninEnd == 8L) {
                failedWrites++
                throw IOException("final range write unavailable")
            }
            checkpoints.persist(it)
        }
        try {
            joinPromotedVectorEvent(live, engine, registry)
            repeat(3) { engine.emitDetection(enin = 7, rpid = "peer-$it", detectedDisplayId = "peer-$it") }
            repeat(99_997) { engine.emitDetection(enin = 7, rpid = "peer-0", detectedDisplayId = "peer-0") }
            live.checkpointSession()
            val proofId = checkpoints.proofIds().single()
            val durable = checkpoints.load(proofId)!!
            engine.emitDetection(enin = 8, rpid = "peer-0", detectedDisplayId = "peer-0")
            live.leaveEvent()
            assertEquals(1, failedWrites)
            val signed = SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)).records.single()
            assertEquals(7L, signed.eninStart)
            assertEquals(7L, signed.eninEnd, "an identical aggregate cannot authorize an unpersisted range")
            assertEquals(durable.aggregate.observationCount,
                SessionAggregateSnapshotStore(SessionAggregateSnapshotStore.defaultFile(directory)).snapshot(proofId)?.observationCount)
            assertTrue(checkpoints.proofIds().isEmpty())
        } finally {
            live.dispose()
        }
    }

    @Test
    fun failedFirstFlushWithoutCheckpointFallsBackToMemory() = runTest {
        val directory = Files.createTempDirectory("checkpoint-missing-fallback").toFile()
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val live = coordinator(directory, engine, registry) { throw IOException("no checkpoint yet") }
        try {
            joinPromotedVectorEvent(live, engine, registry)
            repeat(3) { engine.emitDetection(enin = 7, rpid = "peer-$it", detectedDisplayId = "peer-$it") }
            live.leaveEvent()
            assertEquals(7L, SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)).records.single().eninEnd)
        } finally {
            live.dispose()
        }
    }

    private fun TestScope.coordinator(
        directory: File,
        engine: FakeEventJoinEngine = FakeEventJoinEngine(),
        registry: FakeNearbyEventRegistry = FakeNearbyEventRegistry(),
        cryptography: FakeSensingCryptography = FakeSensingCryptography(),
        persistence: ((SessionCheckpoint) -> Unit)? = null,
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
        checkpointPersistence = persistence,
    )
}

package org.levarac.beid.sensing

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.persistence.SessionAggregateSnapshotStore
import org.levarac.beid.persistence.SessionCheckpointStore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorCheckpointSchedulingTest {
    @Test
    fun detectionBurstCoalescesWritesWithoutCheckpointIoOnTheCallingThread() = runTest {
        val directory = Files.createTempDirectory("checkpoint-burst").toFile()
        val engine = FakeEventJoinEngine()
        val coordinator = recording(directory, engine)
        val store = SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory))
        fun bytes() = store.proofIds().singleOrNull()?.let {
            File(SessionCheckpointStore.defaultDirectory(directory), "$it.json").readText()
        }
        var previous = bytes()
        var writesDuringCallbacks = 0
        repeat(25) {
            engine.emitDetection(enin = 8, rpid = "burst-$it", detectedDisplayId = "burst-device-$it")
            val next = bytes()
            if (next != previous) writesDuringCallbacks++
            previous = next
        }
        assertTrue(writesDuringCallbacks <= 1, "25 detections in one interval must coalesce; writes=$writesDuringCallbacks")
        assertEquals(0, writesDuringCallbacks, "checkpoint I/O must wait for the writer dispatcher")
        assertTrue(store.proofIds().isEmpty())
        runCurrent()
        advanceTimeBy(999)
        runCurrent()
        assertTrue(store.proofIds().isEmpty())
        advanceTimeBy(1)
        runCurrent()
        val checkpoint = store.load(store.proofIds().single())!!
        assertEquals(28, checkpoint.aggregate.observationCount)
        assertEquals(8L, checkpoint.eninEnd)
        coordinator.dispose()
    }

    @Test
    fun onStopFlushReturnsWithLatestDurableEvidenceAndDelayedWorkCannotReplaceIt() = runTest {
        val directory = Files.createTempDirectory("checkpoint-stop-flush").toFile()
        val engine = FakeEventJoinEngine()
        val coordinator = recording(directory, engine)
        engine.emitDetection(enin = 8, rpid = "four", detectedDisplayId = "four")
        // MainActivity.onStop calls this synchronous boundary before super.onStop.
        coordinator.checkpointSession()
        val store = SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory))
        val proofId = store.proofIds().single()
        assertEquals(4, store.load(proofId)?.aggregate?.observationCount)
        assertEquals(8L, store.load(proofId)?.eninEnd)
        assertIs<ScanPhase.Recording>((coordinator.state.value as EventJoinUiState.Sensing).phase)
        assertTrue(SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)).records.isEmpty())

        engine.emitDetection(enin = 9, rpid = "five", detectedDisplayId = "five")
        coordinator.checkpointSession()
        advanceTimeBy(10_000)
        runCurrent()
        assertEquals(5, store.load(proofId)?.aggregate?.observationCount)
        assertEquals(9L, store.load(proofId)?.eninEnd)

        engine.onEvent = null // Process death immediately after onStop, without teardown.
        val recovered = coordinator(directory)
        recovered.drainPendingSubmissionsOnForeground()
        recovered.drainPendingSubmissionsOnForeground()
        recovered.dispose()
        assertEquals(proofId, SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)).records.single().proofId)
        assertEquals(5, SessionAggregateSnapshotStore(SessionAggregateSnapshotStore.defaultFile(directory))
            .snapshot(proofId)?.observationCount)
    }

    @Test
    fun finalizationDiscardsPendingWritesAndCannotRecreateACheckpoint() = runTest {
        val directory = Files.createTempDirectory("checkpoint-finalize-order").toFile()
        val engine = FakeEventJoinEngine()
        val coordinator = recording(directory, engine)
        runCurrent()
        engine.emitDetection(enin = 8, rpid = "four", detectedDisplayId = "four")
        coordinator.leaveEvent()
        coordinator.leaveEvent()
        advanceTimeBy(10_000)
        runCurrent()
        val store = SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory))
        assertTrue(store.proofIds().isEmpty(), "queued recording work must not write after finalization")
        coordinator.dispose()
        val recovered = coordinator(directory)
        recovered.drainPendingSubmissionsOnForeground()
        recovered.dispose()
        val record = SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)).records.single()
        assertEquals(8L, record.eninEnd)
        assertEquals(4, SessionAggregateSnapshotStore(SessionAggregateSnapshotStore.defaultFile(directory))
            .snapshot(record.proofId)?.observationCount)
        assertTrue(store.proofIds().isEmpty())
    }

    private fun TestScope.recording(directory: File, engine: FakeEventJoinEngine): EventJoinCoordinator {
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(directory, engine, registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
        repeat(3) { engine.emitDetection(enin = 7, rpid = "peer-$it", detectedDisplayId = "device-$it") }
        assertIs<ScanPhase.Recording>((coordinator.state.value as EventJoinUiState.Sensing).phase)
        return coordinator
    }

    private fun TestScope.coordinator(
        directory: File,
        engine: FakeEventJoinEngine = FakeEventJoinEngine(),
        registry: FakeNearbyEventRegistry = FakeNearbyEventRegistry(),
    ) = EventJoinCoordinator(
        engine = engine,
        nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS + testScheduler.currentTime },
        coroutineScope = backgroundScope,
        nearbyRegistry = registry,
        sensingCryptography = FakeSensingCryptography(),
        selfProofRecordStore = SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)),
        bindingRecordStore = BindingRecordStore(BindingRecordStore.defaultFile(directory)),
        ledgerFilesDir = directory,
    )
}

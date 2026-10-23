package org.levarac.beid.sensing

import java.io.File
import java.nio.file.Files
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.persistence.SessionAggregateSnapshotStore
import org.levarac.beid.persistence.SessionCheckpointStore
import org.levarac.beid.persistence.SessionCheckpoint
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorCheckpointSchedulingTest {
    @Test
    fun detectionsAfterObservationLimitDoNotScheduleMoreDurableWrites() = runTest {
        val directory = Files.createTempDirectory("checkpoint-saturated").toFile()
        val engine = FakeEventJoinEngine()
        val counts = mutableListOf<Int>()
        // Count the durable-write boundary without writing a 100,000-observation file.
        val coordinator = recording(directory, engine) { counts += it.aggregate.observationCount }
        try {
            repeat(99_997) {
                engine.emitDetection(enin = 7, rpid = "peer-0", detectedDisplayId = "device-0")
            }
            runCurrent()
            advanceTimeBy(2_000)
            runCurrent()
            assertEquals(listOf(100_000), counts)

            repeat(5) {
                engine.emitDetection(enin = 7, rpid = "peer-0", detectedDisplayId = "device-0")
                advanceTimeBy(2_000)
                runCurrent()
            }
            assertEquals(listOf(100_000), counts, "rejected observations must cause zero additional durable writes")
        } finally {
            coordinator.dispose()
        }
    }

    @Test
    fun detectionBurstCoalescesWritesWithoutCheckpointIoOnTheCallingThread() = runTest {
        val directory = Files.createTempDirectory("checkpoint-burst").toFile()
        val engine = FakeEventJoinEngine()
        val store = SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory))
        val callingThread = Thread.currentThread()
        val writes = Collections.synchronizedList(mutableListOf<Thread>())
        val coordinator = recording(directory, engine) {
            store.persist(it)
            writes += Thread.currentThread()
        }
        val worker = Executors.newSingleThreadExecutor()
        try {
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
            worker.submit { testScheduler.runCurrent() }.get(30, TimeUnit.SECONDS)
            advanceTimeBy(999)
            runCurrent()
            assertTrue(store.proofIds().isEmpty())
            worker.submit {
                testScheduler.advanceTimeBy(1)
                testScheduler.runCurrent()
            }.get(30, TimeUnit.SECONDS)
            val checkpoint = store.load(store.proofIds().single())!!
            assertEquals(28, checkpoint.aggregate.observationCount)
            assertEquals(8L, checkpoint.eninEnd)
            assertEquals(1, writes.size, "one actual durable write for the entire interval")
            assertTrue(writes.all { it !== callingThread }, "serialization and fsync must run off the callback thread")
            repeat(25) { engine.emitDetection(enin = 9, rpid = "next-$it", detectedDisplayId = "next-$it") }
            worker.submit {
                testScheduler.runCurrent()
                testScheduler.advanceTimeBy(999)
                testScheduler.runCurrent()
            }.get(30, TimeUnit.SECONDS)
            assertEquals(1, writes.size)
            worker.submit {
                testScheduler.advanceTimeBy(1)
                testScheduler.runCurrent()
            }.get(30, TimeUnit.SECONDS)
            assertEquals(2, writes.size)
            assertEquals(53, store.load(checkpoint.proofId)?.aggregate?.observationCount)
            assertTrue(writes.all { it !== callingThread })
        } finally {
            coordinator.dispose()
            worker.shutdownNow()
        }
    }

    @Test
    fun inFlightOlderWriteFinishesBeforeBoundaryFlushAndCannotRecreateFinalizedInput() = runTest {
        val directory = Files.createTempDirectory("checkpoint-inflight-order").toFile()
        val engine = FakeEventJoinEngine()
        val store = SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory))
        val oldWriteEntered = CountDownLatch(1)
        val releaseOldWrite = CountDownLatch(1)
        val flushStarted = CountDownLatch(1)
        val counts = Collections.synchronizedList(mutableListOf<Int>())
        val coordinator = recording(directory, engine) {
            if (it.aggregate.observationCount == 3) {
                oldWriteEntered.countDown()
                check(releaseOldWrite.await(30, TimeUnit.SECONDS))
            }
            store.persist(it)
            counts += it.aggregate.observationCount
        }
        val worker = Executors.newSingleThreadExecutor()
        val boundary = Executors.newSingleThreadExecutor()
        try {
            val olderWrite = worker.submit {
                testScheduler.runCurrent()
                testScheduler.advanceTimeBy(1_000)
                testScheduler.runCurrent()
            }
            assertTrue(oldWriteEntered.await(30, TimeUnit.SECONDS))
            // This callback must return while old checkpoint I/O is still blocked.
            engine.emitDetection(enin = 8, rpid = "four", detectedDisplayId = "four")
            val flush = boundary.submit {
                flushStarted.countDown()
                coordinator.checkpointSession()
            }
            assertTrue(flushStarted.await(30, TimeUnit.SECONDS))
            assertFalse(flush.isDone, "onStop must wait for durable completion")
            releaseOldWrite.countDown()
            olderWrite.get(30, TimeUnit.SECONDS)
            flush.get(30, TimeUnit.SECONDS)
            val proofId = store.proofIds().single()
            assertEquals(listOf(3, 4), counts.toList(), "an older in-flight write must precede the boundary's latest write")
            assertEquals(4, store.load(proofId)?.aggregate?.observationCount)
            assertEquals(8L, store.load(proofId)?.eninEnd)
            coordinator.leaveEvent()
            advanceTimeBy(10_000)
            runCurrent()
            assertTrue(store.proofIds().isEmpty())
            assertEquals(1, SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)).records.size)
            assertEquals(4, SessionAggregateSnapshotStore(SessionAggregateSnapshotStore.defaultFile(directory))
                .snapshot(proofId)?.observationCount)
        } finally {
            releaseOldWrite.countDown()
            coordinator.dispose()
            worker.shutdownNow()
            boundary.shutdownNow()
        }
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
        runCurrent()
        recovered.drainPendingSubmissionsOnForeground()
        runCurrent()
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
        runCurrent()
        recovered.dispose()
        val record = SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)).records.single()
        assertEquals(8L, record.eninEnd)
        assertEquals(4, SessionAggregateSnapshotStore(SessionAggregateSnapshotStore.defaultFile(directory))
            .snapshot(record.proofId)?.observationCount)
        assertTrue(store.proofIds().isEmpty())
    }

    private fun TestScope.recording(
        directory: File,
        engine: FakeEventJoinEngine,
        persistence: ((SessionCheckpoint) -> Unit)? = null,
    ): EventJoinCoordinator {
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(directory, engine, registry, persistence)
        joinPromotedVectorEvent(coordinator, engine, registry)
        repeat(3) { engine.emitDetection(enin = 7, rpid = "peer-$it", detectedDisplayId = "device-$it") }
        assertIs<ScanPhase.Recording>((coordinator.state.value as EventJoinUiState.Sensing).phase)
        return coordinator
    }

    private fun TestScope.coordinator(
        directory: File,
        engine: FakeEventJoinEngine = FakeEventJoinEngine(),
        registry: FakeNearbyEventRegistry = FakeNearbyEventRegistry(),
        persistence: ((SessionCheckpoint) -> Unit)? = null,
    ) = EventJoinCoordinator(
        engine = engine,
        nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS + testScheduler.currentTime },
        coroutineScope = backgroundScope,
        nearbyRegistry = registry,
        sensingCryptography = FakeSensingCryptography(),
        selfProofRecordStore = SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)),
        bindingRecordStore = BindingRecordStore(BindingRecordStore.defaultFile(directory)),
        ledgerFilesDir = directory,
        checkpointDispatcher = StandardTestDispatcher(testScheduler),
        checkpointPersistence = persistence,
    )
}

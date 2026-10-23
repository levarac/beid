package org.levarac.beid.sensing

import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.levarac.beid.persistence.SessionCheckpoint
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class SessionCheckpointDraftIsolationTest {
    @Test
    fun backgroundAggregationDoesNotHoldTheSharedStorageLock() = aggregationLeavesStorageFree(background = true)

    @Test
    fun boundaryAggregationDoesNotHoldTheSharedStorageLock() = aggregationLeavesStorageFree(background = false)

    private fun aggregationLeavesStorageFree(background: Boolean) = runTest {
        val directory = java.nio.file.Files.createTempDirectory("draft-materialization").toFile()
        val owner = SessionCheckpointRuntimeOwner()
        val serialization = owner.serialization(org.levarac.beid.persistence.SessionCheckpointStore.defaultDirectory(directory))
        val draft = owner.draftStore(org.levarac.beid.persistence.WindowObservationDraftStore.defaultFile(directory))
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val acquired = CountDownLatch(1)
        val worker = Executors.newSingleThreadExecutor()
        val detector = Executors.newSingleThreadExecutor()
        val runtime = AggregationRuntime()
        repeat(1_000) { runtime.recordObservation(7, "peer-$it", "device-$it") }
        val aggregate = runtime.snapshotAggregate()
        val writes = mutableListOf<SessionCheckpoint>()
        val writer = SessionCheckpointWriter(
            backgroundScope, StandardTestDispatcher(testScheduler), { writes += it }, { throw it }, serialization,
        )
        val snapshot = {
            entered.countDown()
            check(release.await(30, TimeUnit.SECONDS))
            SessionCheckpoint(UUID(0, 1), "event", 7, 7, aggregate())
        }
        try {
            val writing = if (background) {
                writer.schedule(snapshot)
                runCurrent()
                advanceTimeBy(1_000)
                worker.submit { testScheduler.runCurrent() }
            } else {
                worker.submit { writer.flush(snapshot) }
            }
            assertTrue(entered.await(30, TimeUnit.SECONDS), "aggregation must be in flight")
            val detection = detector.submit { draft.persist(org.levarac.beid.shared.report.createWindowObservationDraft(
                "00112233-4455-6677-8899-aabbccddeeff", 7, "event", "21".repeat(32),
                "22".repeat(32), "ab".repeat(32), "01" + "10".repeat(15)).draft!!); acquired.countDown() }
            assertTrue(acquired.await(2, TimeUnit.SECONDS), "detection must acquire storage while aggregation is paused")
            release.countDown()
            writing.get(30, TimeUnit.SECONDS)
            detection.get(30, TimeUnit.SECONDS)
            assertEquals(1_000, writes.single().aggregate.observationCount)
        } finally {
            release.countDown()
            worker.shutdown()
            detector.shutdown()
            check(worker.awaitTermination(30, TimeUnit.SECONDS))
            check(detector.awaitTermination(30, TimeUnit.SECONDS))
            writer.close()
        }
    }
}

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
class SessionCheckpointWriterTest {
    @Test
    fun backgroundAggregationDoesNotHoldTheSharedStorageLock() = aggregationLeavesStorageFree(background = true)

    @Test
    fun boundaryAggregationDoesNotHoldTheSharedStorageLock() = aggregationLeavesStorageFree(background = false)

    @Test
    fun boundaryFlushSupersedesAnOlderCheckpointStillBeingMaterialized() = runTest {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val worker = Executors.newSingleThreadExecutor()
        val writes = java.util.Collections.synchronizedList(mutableListOf<SessionCheckpoint>())
        val runtime = AggregationRuntime()
        runtime.recordObservation(7, "peer", "device")
        val old = SessionCheckpoint(UUID(0, 1), "event", 7, 7, runtime.snapshotAggregate()())
        val latest = old.copy(eninEnd = 9)
        val writer = SessionCheckpointWriter(backgroundScope, StandardTestDispatcher(testScheduler),
            { writes += it }, { throw it })
        val boundary = Executors.newSingleThreadExecutor()
        try {
            writer.schedule {
                entered.countDown()
                check(release.await(30, TimeUnit.SECONDS))
                old
            }
            runCurrent()
            advanceTimeBy(1_000)
            val background = worker.submit { testScheduler.runCurrent() }
            assertTrue(entered.await(30, TimeUnit.SECONDS))
            boundary.submit { writer.flush { latest } }.get(2, TimeUnit.SECONDS)
            release.countDown()
            background.get(30, TimeUnit.SECONDS)
            assertEquals(listOf(latest), writes.toList(), "old work must not recreate finalized checkpoint input")
        } finally {
            release.countDown()
            worker.shutdown()
            worker.awaitTermination(30, TimeUnit.SECONDS)
            boundary.shutdown()
            boundary.awaitTermination(30, TimeUnit.SECONDS)
            writer.close()
        }
    }

    private fun aggregationLeavesStorageFree(background: Boolean) = runTest {
        val serialization = SessionCheckpointSerialization()
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
            val detection = detector.submit { serialization.serialized { acquired.countDown() } }
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

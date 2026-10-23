package org.levarac.beid.sensing

import java.io.File
import java.nio.file.Files
import java.util.Collections
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
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
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorCheckpointRecoverySchedulingTest {
    @Test
    fun foregroundDefersCheckpointReadsSigningAndRecordUpdatesAndPublishesRecoveredRecords() = runTest {
        val directory = Files.createTempDirectory("checkpoint-foreground-dispatch").toFile()
        seedCheckpoint(directory)
        // A parse failure makes checkpoint reads observable through the diagnostic seam.
        File(SessionCheckpointStore.defaultDirectory(directory), "${UUID(0, 0)}.json").writeText("invalid")
        val callingThread = Thread.currentThread()
        val workThreads = Collections.synchronizedList(mutableListOf<Thread>())
        val diagnostics = Collections.synchronizedList(mutableListOf<String>())
        val cryptography = object : FakeSensingCryptography() {
            override fun signSelfProof(
                eventIdHash: ByteArray, eventSigningPublicKey: ByteArray, eninStart: Long, eninEnd: Long,
            ): SensingRecoverableSignature? {
                workThreads += Thread.currentThread()
                return super.signSelfProof(eventIdHash, eventSigningPublicKey, eninStart, eninEnd)
            }
        }
        val recovered = coordinator(directory, cryptography = cryptography, diagnostics = {
            workThreads += Thread.currentThread()
            diagnostics += it
        })
        val records = ProofRecordStore(ProofRecordStore.defaultFile(directory))
        val bridge = ProofRecordingBridge(records)
        wireProofRecording(recovered, bridge)
        recovered.onProofSignatureStateChanged = { id, selfProof, binding ->
            workThreads += Thread.currentThread()
            bridge.onProofSignatureStateChanged(id, selfProof, binding)
        }
        val worker = Executors.newSingleThreadExecutor()
        try {
            recovered.drainPendingSubmissionsOnForeground()
            recovered.drainPendingSubmissionsOnForeground()
            assertTrue(diagnostics.isEmpty(), "onResume must not read or parse checkpoints on the calling thread")
            assertTrue(cryptography.calls.isEmpty(), "onResume must not sign on the calling thread")
            assertFalse(records.recordsFlow.value.single().hasSelfProof)
            assertTrue(SessionAggregateSnapshotStore(SessionAggregateSnapshotStore.defaultFile(directory)).records.isEmpty())

            worker.submit { testScheduler.runCurrent() }.get(30, TimeUnit.SECONDS)
            val record = records.recordsFlow.value.single()
            assertTrue(record.hasSelfProof, "the UI's existing StateFlow must publish the recovered signature")
            assertEquals(record.id, SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)).records.single().proofId)
            assertEquals(3, SessionAggregateSnapshotStore(SessionAggregateSnapshotStore.defaultFile(directory))
                .snapshot(record.id)?.observationCount)
            assertTrue(diagnostics.any { it.contains("session_checkpoint_recover_failed") })
            assertTrue(workThreads.isNotEmpty())
            assertTrue(workThreads.all { it !== callingThread }, "parse, sign and durable record callbacks must use the worker")
            recovered.drainPendingSubmissionsOnForeground()
            worker.submit { testScheduler.runCurrent() }.get(30, TimeUnit.SECONDS)
            assertEquals(1, cryptography.calls.count { it is FakeSensingCryptography.Call.SignSelfProof })
            assertEquals(1, records.recordsFlow.value.size)
        } finally {
            recovered.dispose()
            worker.shutdownNow()
        }
    }

    @Test
    fun recoveryWaitsForCheckpointIoAndFinalizationWaitsForRecovery() = runTest {
        val directory = Files.createTempDirectory("checkpoint-recovery-serialization").toFile()
        seedCheckpoint(directory)
        val callingThread = Thread.currentThread()
        val writeEntered = CountDownLatch(1)
        val releaseWrite = CountDownLatch(1)
        val recoveryEntered = CountDownLatch(1)
        val releaseRecovery = CountDownLatch(1)
        val finalizationStarted = CountDownLatch(1)
        val counts = Collections.synchronizedList(mutableListOf<Int>())
        val store = SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory))
        val cryptography = object : FakeSensingCryptography() {
            override fun signSelfProof(
                eventIdHash: ByteArray, eventSigningPublicKey: ByteArray, eninStart: Long, eninEnd: Long,
            ): SensingRecoverableSignature? {
                if (eninStart == 7L) {
                    recoveryEntered.countDown()
                    // Let the synchronous implementation fail without blocking the caller.
                    if (Thread.currentThread() !== callingThread) check(releaseRecovery.await(30, TimeUnit.SECONDS))
                }
                return super.signSelfProof(eventIdHash, eventSigningPublicKey, eninStart, eninEnd)
            }
        }
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val live = coordinator(directory, engine, registry, cryptography, persistence = {
            if (it.aggregate.observationCount == 3) {
                writeEntered.countDown()
                check(releaseWrite.await(30, TimeUnit.SECONDS))
            }
            store.persist(it)
            counts += it.aggregate.observationCount
        })
        joinPromotedVectorEvent(live, engine, registry)
        repeat(3) { engine.emitDetection(enin = 9, rpid = "live-$it", detectedDisplayId = "live-$it") }
        val worker = Executors.newSingleThreadExecutor()
        val boundary = Executors.newSingleThreadExecutor()
        try {
            val writes = worker.submit {
                testScheduler.runCurrent()
                testScheduler.advanceTimeBy(1_000)
                testScheduler.runCurrent()
            }
            assertTrue(writeEntered.await(30, TimeUnit.SECONDS))
            live.drainPendingSubmissionsOnForeground()
            assertEquals(1L, recoveryEntered.count, "recovery must wait for the in-flight checkpoint write")
            releaseWrite.countDown()
            assertTrue(recoveryEntered.await(30, TimeUnit.SECONDS))

            engine.emitDetection(enin = 10, rpid = "four", detectedDisplayId = "four")
            val finalize = boundary.submit {
                finalizationStarted.countDown()
                live.leaveEvent()
            }
            assertTrue(finalizationStarted.await(30, TimeUnit.SECONDS))
            assertFalse(finalize.isDone, "finalization must wait for recovery's store/signing transaction")
            assertEquals(listOf(3), counts.toList())
            releaseRecovery.countDown()
            writes.get(30, TimeUnit.SECONDS)
            finalize.get(30, TimeUnit.SECONDS)
            worker.submit {
                testScheduler.advanceTimeBy(10_000)
                testScheduler.runCurrent()
            }.get(30, TimeUnit.SECONDS)
            assertEquals(listOf(3, 4), counts.toList())
            assertTrue(store.proofIds().isEmpty(), "no delayed snapshot may recreate finalized recovery input")
            val proofs = SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)).records
            assertEquals(2, proofs.size)
            assertEquals(setOf(7L, 10L), proofs.map { it.eninEnd }.toSet())
        } finally {
            releaseWrite.countDown()
            releaseRecovery.countDown()
            live.dispose()
            worker.shutdownNow()
            boundary.shutdownNow()
        }
    }

    @Test
    fun foregroundFlushWaitsForOnlyOneRetainedCheckpointAndMatchesSerialRecovery() = runTest {
        boundaryWaitsForOnlyOneRetainedCheckpoint(finalize = false)
    }

    @Test
    fun finalizationWaitsForOnlyOneRetainedCheckpointAndMatchesSerialRecovery() = runTest {
        boundaryWaitsForOnlyOneRetainedCheckpoint(finalize = true)
    }

    private fun TestScope.boundaryWaitsForOnlyOneRetainedCheckpoint(finalize: Boolean) {
        val directory = Files.createTempDirectory("checkpoint-recovery-backlog").toFile()
        val seedDirectory = File(directory, "seed")
        seedCheckpoint(seedDirectory)
        val seedStore = SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(seedDirectory))
        val template = seedStore.load(seedStore.proofIds().single())!!
        val templateRecord = ProofRecordStore(ProofRecordStore.defaultFile(seedDirectory)).records.single()
        val retained = (1L..3L).map { template.copy(proofId = UUID(0, it), eninStart = it, eninEnd = it) }
        fun seed(target: File) {
            val checkpoints = SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(target))
            val records = ProofRecordStore(ProofRecordStore.defaultFile(target))
            retained.forEach {
                checkpoints.persist(it)
                records.add(templateRecord.copy(id = it.proofId))
            }
        }
        fun recording(target: File, cryptography: FakeSensingCryptography): Pair<EventJoinCoordinator, ProofRecordStore> {
            seed(target)
            val engine = FakeEventJoinEngine()
            val registry = FakeNearbyEventRegistry()
            val live = coordinator(target, engine, registry, cryptography)
            val records = ProofRecordStore(ProofRecordStore.defaultFile(target))
            wireProofRecording(live, ProofRecordingBridge(records))
            joinPromotedVectorEvent(live, engine, registry)
            repeat(3) { engine.emitDetection(enin = 9, rpid = "live-$it", detectedDisplayId = "live-$it") }
            engine.emitDetection(enin = 10, rpid = "four", detectedDisplayId = "four")
            return live to records
        }
        fun evidence(target: File): List<Pair<List<Any>, String>> {
            val aggregates = SessionAggregateSnapshotStore(SessionAggregateSnapshotStore.defaultFile(target))
            return SelfProofRecordStore(SelfProofRecordStore.defaultFile(target)).records.sortedBy { it.eninStart }.map {
                listOf(it.eventCode, it.eventIdHashHex, it.eventSigningPublicKeyHex, it.eninStart, it.eninEnd,
                    it.ownerPublicKeyHex, it.signatureRHex, it.signatureSHex, it.signatureV) to aggregates.records.single { row -> row.proofId == it.proofId }.snapshotText
            }
        }
        val serialDirectory = File(directory, "serial")
        val (serial, serialRecords) = recording(serialDirectory, FakeSensingCryptography())
        serial.drainPendingSubmissionsOnForeground()
        testScheduler.runCurrent()
        if (finalize) serial.leaveEvent() else serial.checkpointSession()
        serial.leaveEvent()
        serial.dispose()
        val expected = evidence(serialDirectory)
        assertEquals(4, expected.size)
        assertTrue(serialRecords.recordsFlow.value.all { it.hasSelfProof })

        val firstSignEntered = CountDownLatch(1)
        val releaseFirstSign = CountDownLatch(1)
        val releaseLaterSigns = CountDownLatch(1)
        val completed = Collections.synchronizedList(mutableListOf<Long>())
        val slowCryptography = object : FakeSensingCryptography() {
            override fun signSelfProof(
                eventIdHash: ByteArray, eventSigningPublicKey: ByteArray, eninStart: Long, eninEnd: Long,
            ): SensingRecoverableSignature? {
                if (eninStart == 1L) {
                    firstSignEntered.countDown()
                    check(releaseFirstSign.await(30, TimeUnit.SECONDS))
                } else if (eninStart < 9L) {
                    check(releaseLaterSigns.await(30, TimeUnit.SECONDS))
                }
                return super.signSelfProof(eventIdHash, eventSigningPublicKey, eninStart, eninEnd).also {
                    completed += eninStart
                }
            }
        }
        val concurrentDirectory = File(directory, "concurrent")
        val (live, records) = recording(concurrentDirectory, slowCryptography)
        val worker = Executors.newSingleThreadExecutor()
        val boundary = Executors.newSingleThreadExecutor()
        val boundaryStarted = CountDownLatch(1)
        val boundaryThread = java.util.concurrent.atomic.AtomicReference<Thread>()
        try {
            live.drainPendingSubmissionsOnForeground()
            val recovery = worker.submit { testScheduler.runCurrent() }
            assertTrue(firstSignEntered.await(30, TimeUnit.SECONDS))
            val flush = boundary.submit {
                boundaryThread.set(Thread.currentThread())
                boundaryStarted.countDown()
                if (finalize) live.leaveEvent() else live.checkpointSession()
            }
            assertTrue(boundaryStarted.await(30, TimeUnit.SECONDS))
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (boundaryThread.get().state !in setOf(Thread.State.BLOCKED, Thread.State.WAITING) &&
                System.nanoTime() < deadline) Thread.yield()
            assertTrue(boundaryThread.get().state in setOf(Thread.State.BLOCKED, Thread.State.WAITING),
                "the boundary must be waiting before the first signature is released")
            assertFalse(flush.isDone)
            releaseFirstSign.countDown()
            try {
                flush.get(5, TimeUnit.SECONDS)
            } catch (error: java.util.concurrent.TimeoutException) {
                throw AssertionError("the boundary must finish after one recovered checkpoint, before later signatures", error)
            }
            assertEquals(listOf(1L), completed.filter { it < 9L })
            releaseLaterSigns.countDown()
            recovery.get(30, TimeUnit.SECONDS)
            live.leaveEvent()
            assertEquals(expected, evidence(concurrentDirectory), "concurrent recovery must equal the serial result")
            assertEquals(4, records.recordsFlow.value.size)
            assertTrue(records.recordsFlow.value.all { it.hasSelfProof }, "recovery must reach the existing records flow")
            live.drainPendingSubmissionsOnForeground()
            worker.submit { testScheduler.runCurrent() }.get(30, TimeUnit.SECONDS)
            assertEquals(expected, evidence(concurrentDirectory))
            assertEquals(4, completed.size, "each proof must be signed once")
            assertTrue(SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(concurrentDirectory)).proofIds().isEmpty())
        } finally {
            releaseFirstSign.countDown()
            releaseLaterSigns.countDown()
            worker.shutdown()
            assertTrue(worker.awaitTermination(30, TimeUnit.SECONDS))
            boundary.shutdown()
            assertTrue(boundary.awaitTermination(30, TimeUnit.SECONDS))
            live.dispose()
        }
    }

    private fun TestScope.seedCheckpoint(directory: File) {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val first = coordinator(directory, engine, registry)
        wireProofRecording(first, ProofRecordingBridge(ProofRecordStore(ProofRecordStore.defaultFile(directory))))
        joinPromotedVectorEvent(first, engine, registry)
        repeat(3) { engine.emitDetection(enin = 7, rpid = "peer-$it", detectedDisplayId = "peer-$it") }
        first.checkpointSession()
        engine.onEvent = null // Process death, without graceful finalization.
    }

    private fun TestScope.coordinator(
        directory: File,
        engine: FakeEventJoinEngine = FakeEventJoinEngine(),
        registry: FakeNearbyEventRegistry = FakeNearbyEventRegistry(),
        cryptography: FakeSensingCryptography = FakeSensingCryptography(),
        diagnostics: (String) -> Unit = {},
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
        joinDiagnostics = diagnostics,
    )
}

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
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
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

    @Test
    fun anotherCoordinatorSkipsALiveProofUntilItsOwnerAttemptsFinalization() = runTest {
        val directory = Files.createTempDirectory("checkpoint-live-owner").toFile()
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val live = coordinator(directory, engine, registry, FakeSensingCryptography(selfProofSignatureResult = null))
        joinPromotedVectorEvent(live, engine, registry)
        repeat(3) { engine.emitDetection(enin = 7, rpid = "peer-$it", detectedDisplayId = "peer-$it") }
        live.checkpointSession()
        val checkpoints = SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory))
        val proofId = checkpoints.proofIds().single()
        val cryptography = FakeSensingCryptography()
        val otherActivity = coordinator(directory, cryptography = cryptography)
        try {
            repeat(2) {
                otherActivity.drainPendingSubmissionsOnForeground()
                runCurrent()
            }
            assertTrue(cryptography.calls.isEmpty(), "another Activity must not sign a live proof")
            assertTrue(SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)).records.isEmpty())
            assertEquals(listOf(proofId), checkpoints.proofIds())

            engine.emitDetection(enin = 8, rpid = "four", detectedDisplayId = "four")
            live.checkpointSession()
            assertEquals(8L, checkpoints.load(proofId)?.eninEnd, "the live session must continue")
            live.leaveEvent() // No signature: ownership must still end after this attempt.
            assertEquals(listOf(proofId), checkpoints.proofIds())
            otherActivity.drainPendingSubmissionsOnForeground()
            runCurrent()
            val record = SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)).records.single()
            assertEquals(proofId, record.proofId)
            assertEquals(7L, record.eninStart)
            assertEquals(8L, record.eninEnd)
            assertEquals(1, cryptography.calls.count { it is FakeSensingCryptography.Call.SignSelfProof })
            assertTrue(checkpoints.proofIds().isEmpty())
        } finally {
            live.dispose()
            otherActivity.dispose()
        }
    }

    @Test
    fun checkpointEncoderRejectsInvertedRangeWithoutReplacingDurableBytes() = runTest {
        val directory = Files.createTempDirectory("checkpoint-inverted-encoder").toFile()
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val live = coordinator(directory, engine, registry)
        try {
            joinPromotedVectorEvent(live, engine, registry)
            repeat(3) { engine.emitDetection(enin = 7, rpid = "peer-$it", detectedDisplayId = "peer-$it") }
            live.checkpointSession()
            val checkpoints = SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory))
            val proofId = checkpoints.proofIds().single()
            val durable = checkpoints.load(proofId)!!
            val file = File(SessionCheckpointStore.defaultDirectory(directory), "$proofId.json")
            val bytes = file.readBytes()
            assertFailsWith<IllegalArgumentException> {
                checkpoints.persist(durable.copy(eninEnd = 6))
            }
            assertTrue(bytes.contentEquals(file.readBytes()), "rejected ranges must leave durable bytes untouched")
            assertEquals(7L, checkpoints.load(proofId)?.eninEnd)
        } finally {
            live.dispose()
        }
    }

    @Test
    fun checkpointAndSignatureEndRemainAtTheMaximumObservedEnin() = runTest {
        val directory = Files.createTempDirectory("checkpoint-monotonic-range").toFile()
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val live = coordinator(directory, engine, registry)
        try {
            joinPromotedVectorEvent(live, engine, registry)
            repeat(3) { engine.emitDetection(enin = 7, rpid = "peer-$it", detectedDisplayId = "peer-$it") }
            live.checkpointSession()
            val checkpoints = SessionCheckpointStore(SessionCheckpointStore.defaultDirectory(directory))
            val proofId = checkpoints.proofIds().single()
            for (enin in listOf(9L, 6L, 8L)) {
                engine.emitDetection(enin = enin, rpid = "peer-$enin", detectedDisplayId = "peer-$enin")
                live.checkpointSession()
                val checkpoint = assertNotNull(runCatching { checkpoints.load(proofId) }.getOrNull(),
                    "every encoded checkpoint must remain loadable after backward observations")
                assertEquals(7L, checkpoint.eninStart)
                assertEquals(9L, checkpoint.eninEnd, "checkpoint range must not move backward")
            }
            live.leaveEvent()
            val record = SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)).records.single()
            assertEquals(7L, record.eninStart)
            assertEquals(9L, record.eninEnd)
            assertTrue(checkpoints.proofIds().isEmpty())
        } finally {
            live.dispose()
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

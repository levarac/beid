package org.levarac.beid.sensing

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.persistence.SessionAggregateSnapshotStore
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

package org.levarac.beid.sensing

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.persistence.SessionCheckpointStore
import org.levarac.beid.wireProofRecording
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class CheckpointEventIdentityTest {
    @Test
    fun recordingCheckpointPersistsVerifiedIdentity() = runTest {
        val directory = recordingCheckpoint()
        val checkpoint = SessionCheckpointStore.defaultDirectory(directory).listFiles()!!.single()
        val saved = Json.parseToJsonElement(checkpoint.readText()).jsonObject
            .getValue("records").jsonArray.single().jsonObject
        assertEquals(EVENT_NAME, saved["eventName"]?.jsonPrimitive?.contentOrNull)
        assertEquals(EVENT_ID, saved["eventIdHex"]?.jsonPrimitive?.contentOrNull)
    }

    @Test
    fun missingRowIsReconstructedWithCheckpointIdentity() = recovery(missingRow = true)

    @Test
    fun existingLegacyRowReceivesCheckpointIdentityInTheSignatureWrite() = recovery(legacyRow = true)

    @Test
    fun legacyCheckpointPreservesIdentityAlreadyInTheRow() = recovery(legacyCheckpoint = true)

    @Test
    fun legacyCheckpointWithoutARowDoesNotInventIdentityFromTheCode() = recovery(
        legacyCheckpoint = true, missingRow = true, expectedName = null, expectedId = null,
    )

    @Test
    fun checkpointWithOnlyANameDoesNotInventAnIdentifier() = recovery(
        missingRow = true, omittedCheckpointFields = setOf("eventIdHex"), expectedId = null,
    )

    @Test
    fun checkpointWithOnlyAnIdentifierDoesNotInventAName() = recovery(
        missingRow = true, omittedCheckpointFields = setOf("eventName"), expectedName = null,
    )

    private fun recovery(
        legacyCheckpoint: Boolean = false,
        missingRow: Boolean = false,
        legacyRow: Boolean = false,
        omittedCheckpointFields: Set<String> = emptySet(),
        expectedName: String? = EVENT_NAME,
        expectedId: String? = EVENT_ID,
    ) = runTest {
        val directory = recordingCheckpoint()
        val checkpoint = SessionCheckpointStore.defaultDirectory(directory).listFiles()!!.single()
        if (legacyCheckpoint || omittedCheckpointFields.isNotEmpty()) {
            omitFields(checkpoint, if (legacyCheckpoint) IDENTITY_FIELDS else omittedCheckpointFields)
        }
        val rowsFile = ProofRecordStore.defaultFile(directory)
        if (missingRow) assertTrue(rowsFile.delete())
        if (legacyRow) omitFields(rowsFile, IDENTITY_FIELDS)
        // A fresh process must read the files rather than the old store's cache.
        simulateCheckpointProcessDeath(directory)
        val recovered = coordinator(directory)
        val rows = ProofRecordStore(rowsFile)
        wireProofRecording(recovered, ProofRecordingBridge(rows))
        try {
            recovered.drainPendingSubmissionsOnForeground()
            runCurrent()
            val row = ProofRecordStore(rowsFile).records.single()
            assertTrue(row.hasSelfProof)
            assertEquals(EVENT_ID, row.eventCode)
            assertEquals(expectedName, row.eventName)
            assertEquals(expectedId, row.eventIdHex)
            assertEquals(row, rows.recordsFlow.value.single())
            assertTrue(!checkpoint.exists(), "clear only after the enriched row has been read back")
        } finally {
            recovered.dispose()
        }
    }

    private fun TestScope.recordingCheckpoint(): File {
        val directory = Files.createTempDirectory("checkpoint-event-identity").toFile()
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val live = coordinator(directory, engine, registry)
        wireProofRecording(live, ProofRecordingBridge(ProofRecordStore(ProofRecordStore.defaultFile(directory))))
        joinPromotedVectorEvent(live, engine, registry)
        repeat(3) { engine.emitDetection(enin = 7, rpid = "peer-$it", detectedDisplayId = "device-$it") }
        val phase = assertIs<ScanPhase.Recording>((live.state.value as EventJoinUiState.Sensing).phase)
        assertEquals(EVENT_NAME, phase.session.eventName)
        assertEquals(EVENT_ID, phase.session.eventIdHex)
        live.checkpointSession()
        engine.onEvent = null
        return directory
    }

    private fun TestScope.coordinator(
        directory: File,
        engine: FakeEventJoinEngine = FakeEventJoinEngine(),
        registry: FakeNearbyEventRegistry = FakeNearbyEventRegistry(),
    ) = EventJoinCoordinator(
        engine = engine,
        nearbyRegistry = registry,
        nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS + testScheduler.currentTime },
        coroutineScope = backgroundScope,
        sensingCryptography = FakeSensingCryptography(),
        selfProofRecordStore = SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)),
        bindingRecordStore = BindingRecordStore(BindingRecordStore.defaultFile(directory)),
        ledgerFilesDir = directory,
        checkpointRuntimeOwner = SessionCheckpointRuntimeOwner(),
        checkpointDispatcher = StandardTestDispatcher(testScheduler),
    )

    private fun omitFields(file: File, fields: Set<String>) {
        val root = Json.parseToJsonElement(file.readText()).jsonObject
        file.writeText(JsonObject(root + ("records" to JsonArray(root.getValue("records").jsonArray.map {
            JsonObject(it.jsonObject - fields)
        }))).toString())
    }

    private companion object {
        const val EVENT_NAME = "Barnard Relay Conformance Event 0123456789 abcdefghijklmno"
        const val EVENT_ID = NearbyEventPromotionFixture.EVENT_ID_HEX
        val IDENTITY_FIELDS = setOf("eventName", "eventIdHex")
    }
}

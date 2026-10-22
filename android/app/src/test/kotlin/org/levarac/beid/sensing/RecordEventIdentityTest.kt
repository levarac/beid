package org.levarac.beid.sensing

import java.io.File
import java.util.UUID
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.ui.screens.toRecordListItem
import org.levarac.beid.wireProofRecording

@OptIn(ExperimentalCoroutinesApi::class)
class RecordEventIdentityTest {
    @get:Rule
    val tempFolder = TemporaryFolder()

    @Test
    fun verifiedNameObtainedAtJoinIsShownAfterRecordStoreReload() = runTest {
        val file = File(tempFolder.root, "records.json")
        val store = ProofRecordStore(file)
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = EventJoinCoordinator(
            engine = engine,
            nearbyRegistry = registry,
            nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS + testScheduler.currentTime },
            coroutineScope = backgroundScope,
            sensingCryptography = FakeSensingCryptography(),
            selfProofRecordStore = SelfProofRecordStore(File(tempFolder.root, "self-proofs.json")),
            bindingRecordStore = BindingRecordStore(File(tempFolder.root, "bindings.json")),
        )
        try {
            wireProofRecording(coordinator, ProofRecordingBridge(store))
            joinPromotedVectorEvent(coordinator, engine, registry)
            engine.emitDetection(enin = 1, rpid = "aa", detectedDisplayId = "device-1")
            engine.emitDetection(enin = 2, rpid = "bb", detectedDisplayId = "device-2")
            engine.emitDetection(enin = 3, rpid = "cc", detectedDisplayId = "device-3")
            coordinator.leaveEvent()

            val reloaded = ProofRecordStore(file)
            assertFalse(reloaded.isPersistenceSuspended)
            assertEquals(EVENT_NAME, reloaded.records.single().toRecordListItem().eventLabel)
            val saved = Json.parseToJsonElement(file.readText()).jsonObject
                .getValue("records").jsonArray.single().jsonObject
            assertEquals(EVENT_NAME, saved["eventName"]?.jsonPrimitive?.contentOrNull)
            assertEquals(NearbyEventPromotionFixture.EVENT_ID_HEX, saved["eventIdHex"]?.jsonPrimitive?.contentOrNull)
        } finally {
            coordinator.dispose()
        }
    }

    @Test
    fun oldJsonWithoutIdentityFieldsDecodesWithoutInventingANameOrIdentifier() {
        val file = File(tempFolder.root, "old-records.json")
        val id = UUID.fromString("12345678-1234-1234-1234-123456789abc")
        file.writeText("""{"schemaVersion":1,"records":[{"id":"$id","eventCode":"OLD-EVENT","createdAt":"2026-01-01T00:00:00Z","peersVerified":2,"hasSelfProof":false,"hasBinding":false}]}""")

        val store = ProofRecordStore(file)
        assertFalse(store.isPersistenceSuspended)
        assertEquals("OLD-EVENT", store.records.single().toRecordListItem().eventLabel)
        store.updatePeersVerified(id, 4)
        val reloaded = ProofRecordStore(file)
        assertEquals(4, reloaded.records.single().peersVerified)
        val saved = Json.parseToJsonElement(file.readText()).jsonObject
            .getValue("records").jsonArray.single().jsonObject
        assertNull(saved["eventName"]?.jsonPrimitive?.contentOrNull)
        assertNull(saved["eventIdHex"]?.jsonPrimitive?.contentOrNull)
    }

    private companion object {
        const val EVENT_NAME = "Barnard Relay Conformance Event 0123456789 abcdefghijklmno"
    }
}

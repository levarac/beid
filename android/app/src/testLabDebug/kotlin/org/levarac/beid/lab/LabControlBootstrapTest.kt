package org.levarac.beid.lab

import kotlin.test.Test
import kotlin.test.assertFailsWith
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class LabControlBootstrapTest {
    @Test
    fun identityRequiresExactHostFields() {
        assertFailsWith<IllegalArgumentException> {
            LabControlIdentity("", "participant", "device-1", 1, "token", 1)
        }
        assertFailsWith<IllegalArgumentException> {
            LabControlIdentity("run-1", "participant", "device-1", 1, "token", 2)
        }
    }

    @Test
    fun missingBrokerFailsClosed() {
        val identity = LabControlIdentity("run-1", "participant", "device-1", 1, "token", 1)
        val broker = object : LabWebSocketClient {
            override fun connect(url: String, hello: LabHello, productionState: () -> String, nearbyCandidates: () -> List<String>, records: () -> List<LabRecordMetadata>, joinNearbyEvent: (String, (Boolean, String?) -> Unit) -> Unit, onSnapshot: (LabSnapshot) -> Unit) = Unit
            override fun stop() = Unit
        }
        val result = LabControlBootstrap(identity, "", broker, { "state=idle" }, { emptyList() }, { _, completion -> completion(false, "not_connected") }).start()
        assertTrue(result.isFailure)
    }

    @Test
    fun joinGateRejectsStaleCandidateGenerationAndDuplicateWithoutReentry() {
        val gate = LabJoinRequestGate()
        assertTrue(gate.rejectReason("r1", 1, 1, listOf("candidate"), "candidate") == null)
        assertTrue(gate.rejectReason("r1", 1, 1, listOf("candidate"), "candidate") == "duplicate_request")
        assertTrue(gate.rejectReason("r2", 1, 1, emptyList(), "candidate") == "candidate_not_currently_verified")
        assertTrue(gate.rejectReason("r3", 2, 1, listOf("candidate"), "candidate") == "generation_mismatch")
    }

    @Test
    fun recordsProjectionAlwaysCarriesStrictFieldsAndHonestNulls() {
        val json = labRecordsJson(listOf(LabRecordMetadata("w1", "e1", null, "PREPARED", false, "timeout")))
        val record = json.single().jsonObject
        assertEquals(setOf("window_id", "event_id", "observation_digest", "status", "receipt_stored", "terminal_error"), record.keys)
        assertTrue(record["observation_digest"] is kotlinx.serialization.json.JsonNull)
        assertEquals("timeout", record["terminal_error"]?.jsonPrimitive?.content)
    }
}

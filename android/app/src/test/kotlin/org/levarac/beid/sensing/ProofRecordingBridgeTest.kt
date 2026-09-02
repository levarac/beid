package org.levarac.beid.sensing

import java.io.File
import java.time.Instant
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import org.levarac.beid.persistence.ProofRecordStore

/**
 * [ProofRecordingBridge] will eventually be wired to three callback
 * properties #235 is adding to [EventJoinCoordinator] (not this worker's
 * file to edit for this round) — built and tested standalone here so that
 * wiring is a one-line assignment once those properties exist.
 */
class ProofRecordingBridgeTest {
    @get:Rule
    val tempFolder = TemporaryFolder()

    private fun store(name: String = "proof-records-v1.json") =
        ProofRecordStore(File(tempFolder.root, name))

    @Test
    fun onProofCollectedAddsARecordWithNoSignatureEvidenceYet() {
        val store = store()
        val bridge = ProofRecordingBridge(store, now = { Instant.parse("2026-01-01T00:00:00Z") })
        val proofId = UUID.randomUUID()

        bridge.onProofCollected(proofId, eventCode = "ETHTOKYO2026", peersVerified = 2)

        val record = store.recordForId(proofId)
        assertNotNull(record)
        assertEquals("ETHTOKYO2026", record.eventCode)
        assertEquals(2, record.peersVerified)
        assertEquals(Instant.parse("2026-01-01T00:00:00Z"), record.createdAt)
        assertFalse(record.hasSelfProof)
        assertFalse(record.hasBinding)
    }

    @Test
    fun onPeersVerifiedChangedUpdatesTheExistingRecord() {
        val store = store()
        val bridge = ProofRecordingBridge(store)
        val proofId = UUID.randomUUID()
        bridge.onProofCollected(proofId, eventCode = "ETHTOKYO2026", peersVerified = 1)

        bridge.onPeersVerifiedChanged(proofId, peersVerified = 6)

        assertEquals(6, store.recordForId(proofId)?.peersVerified)
    }

    @Test
    fun onProofSignatureStateChangedUpdatesTheExistingRecord() {
        val store = store()
        val bridge = ProofRecordingBridge(store)
        val proofId = UUID.randomUUID()
        bridge.onProofCollected(proofId, eventCode = "ETHTOKYO2026", peersVerified = 1)

        bridge.onProofSignatureStateChanged(proofId, hasSelfProof = true, hasBinding = false)

        val record = store.recordForId(proofId)
        assertTrue(record?.hasSelfProof == true)
        assertFalse(record?.hasBinding == true)
    }

    /**
     * Demonstrates the class's thread-safety doc claim rather than merely
     * asserting it: #235's exact invocation thread is still unresolved (see
     * the class kdoc), and a real Android callback data race landed in this
     * repo two days before this test was written (commit `1c7db20`) from
     * exactly that kind of unstated threading assumption.
     */
    @Test
    fun concurrentCallsFromMultipleThreadsDoNotLoseUpdatesOrCrash() {
        val store = store()
        val bridge = ProofRecordingBridge(store)
        val threadCount = 20
        val ids = List(threadCount) { UUID.randomUUID() }
        val executor = Executors.newFixedThreadPool(threadCount)
        try {
            val futures = ids.mapIndexed { index, id ->
                executor.submit { bridge.onProofCollected(id, eventCode = "EVENT-$index", peersVerified = index) }
            }
            futures.forEach { it.get(10, TimeUnit.SECONDS) }
        } finally {
            executor.shutdown()
        }

        assertEquals(threadCount, store.records.size)
        ids.forEach { id -> assertNotNull(store.recordForId(id)) }
        // Regression check for the durable-write/flow-assignment ordering gap
        // ProofRecordStore's own outer lock closes — recordsFlow must reflect
        // every write, not just the durable file (store.records above).
        assertEquals(threadCount, store.recordsFlow.value.size)
    }
}

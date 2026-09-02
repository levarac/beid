package org.levarac.beid.persistence

import java.io.File
import java.time.Instant
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.junit.Rule
import org.junit.rules.TemporaryFolder

/**
 * On-device JSON store for collected [ProofRecord]s — same pattern as
 * [BindingRecordStoreTest]/[SelfProofRecordStoreTest], plus coverage for the
 * mutation surface ([ProofRecordStore.updatePeersVerified]/
 * [ProofRecordStore.updateSignatureState]) and the reactive [ProofRecordStore.recordsFlow]
 * the records list screen reads.
 */
class ProofRecordStoreTest {
    @get:Rule
    val tempFolder = TemporaryFolder()

    private fun record(
        id: UUID = UUID.randomUUID(),
        eventCode: String = "TEST-EVENT",
        createdAt: Instant = Instant.parse("2026-01-01T00:00:00Z"),
        peersVerified: Int = 1,
        hasSelfProof: Boolean = false,
        hasBinding: Boolean = false,
    ) = ProofRecord(
        id = id,
        eventCode = eventCode,
        createdAt = createdAt,
        peersVerified = peersVerified,
        hasSelfProof = hasSelfProof,
        hasBinding = hasBinding,
    )

    @Test
    fun addPersistsAndANewInstanceLoadsItBack() {
        val file = File(tempFolder.root, "proof-records-v1.json")
        val original = record()

        ProofRecordStore(file).add(original)
        val reloaded = ProofRecordStore(file)

        assertEquals(listOf(original), reloaded.records)
    }

    @Test
    fun recordForIdFindsTheFirstMatch() {
        val file = File(tempFolder.root, "proof-records-v1.json")
        val id = UUID.randomUUID()
        val store = ProofRecordStore(file)
        store.add(record())
        store.add(record(id = id))

        assertEquals(id, store.recordForId(id)?.id)
        assertNull(store.recordForId(UUID.randomUUID()))
    }

    @Test
    fun updatePeersVerifiedPersistsAndIsVisibleAfterReload() {
        val file = File(tempFolder.root, "proof-records-v1.json")
        val id = UUID.randomUUID()
        val store = ProofRecordStore(file)
        store.add(record(id = id, peersVerified = 1))

        store.updatePeersVerified(id, 5)

        assertEquals(5, store.recordForId(id)?.peersVerified)
        val reloaded = ProofRecordStore(file)
        assertEquals(5, reloaded.recordForId(id)?.peersVerified)
    }

    @Test
    fun updateSignatureStatePersistsAndIsVisibleAfterReload() {
        val file = File(tempFolder.root, "proof-records-v1.json")
        val id = UUID.randomUUID()
        val store = ProofRecordStore(file)
        store.add(record(id = id))

        store.updateSignatureState(id, hasSelfProof = true, hasBinding = true)

        val updated = store.recordForId(id)
        assertTrue(updated?.hasSelfProof == true)
        assertTrue(updated?.hasBinding == true)
        val reloaded = ProofRecordStore(file)
        assertTrue(reloaded.recordForId(id)?.hasSelfProof == true)
        assertTrue(reloaded.recordForId(id)?.hasBinding == true)
    }

    @Test
    fun recordsFlowEmitsAfterAddAndAfterEachUpdate() {
        val file = File(tempFolder.root, "proof-records-v1.json")
        val id = UUID.randomUUID()
        val store = ProofRecordStore(file)
        assertEquals(emptyList(), store.recordsFlow.value)

        store.add(record(id = id, peersVerified = 1))
        assertEquals(listOf(1), store.recordsFlow.value.map { it.peersVerified })

        store.updatePeersVerified(id, 7)
        assertEquals(listOf(7), store.recordsFlow.value.map { it.peersVerified })

        store.updateSignatureState(id, hasSelfProof = true, hasBinding = false)
        assertTrue(store.recordsFlow.value.single().hasSelfProof)
    }

    @Test
    fun aMissingFileStartsEmptyWithoutThrowing() {
        val file = File(tempFolder.root, "does-not-exist.json")

        assertTrue(ProofRecordStore(file).records.isEmpty())
    }

    @Test
    fun mutationsAreNoOpsWhenPersistenceIsSuspended() {
        val file = File(tempFolder.root, "proof-records-v1.json")
        file.writeText("not valid json{{{")

        val store = ProofRecordStore(file)
        assertTrue(store.isPersistenceSuspended)

        val id = UUID.randomUUID()
        store.add(record(id = id))
        assertTrue(store.records.isEmpty())
        assertTrue(store.recordsFlow.value.isEmpty())

        store.updatePeersVerified(id, 5)
        store.updateSignatureState(id, hasSelfProof = true, hasBinding = true)
        assertFalse(store.records.any { it.id == id })

        assertEquals(
            "not valid json{{{",
            file.readText(),
            "a suspended store must never overwrite bytes it never captured",
        )
    }
}

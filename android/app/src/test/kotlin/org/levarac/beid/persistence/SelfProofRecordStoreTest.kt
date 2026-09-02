package org.levarac.beid.persistence

import java.io.File
import java.time.Instant
import java.util.UUID
import org.levarac.beid.sensing.SensingRecoverableSignature
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.junit.Rule
import org.junit.rules.TemporaryFolder

/** On-device JSON store for owner-key-signed self-proofs — same pattern as [BindingRecordStore]. */
class SelfProofRecordStoreTest {
    @get:Rule
    val tempFolder = TemporaryFolder()

    private fun record(proofId: UUID = UUID.randomUUID()) = SelfProofRecord(
        proofId = proofId,
        eventCode = "TEST-EVENT",
        eventIdHash = ByteArray(32) { 0xAB.toByte() },
        eventSigningPublicKey = byteArrayOf(0x02, 0xC6.toByte()),
        eninStart = 100,
        eninEnd = 200,
        ownerPublicKey = byteArrayOf(0x03, 0x87.toByte()),
        signature = SensingRecoverableSignature(r = byteArrayOf(0x01), s = byteArrayOf(0x02), v = 0),
        signedAt = Instant.parse("2026-01-01T00:00:00Z"),
    )

    @Test
    fun addPersistsAndANewInstanceLoadsItBack() {
        val file = File(tempFolder.root, "self-proofs.json")
        val original = record()

        SelfProofRecordStore(file).add(original)
        val reloaded = SelfProofRecordStore(file)

        assertEquals(listOf(original), reloaded.records)
    }

    @Test
    fun recordForProofIdFindsTheFirstMatch() {
        val file = File(tempFolder.root, "self-proofs.json")
        val proofId = UUID.randomUUID()
        val store = SelfProofRecordStore(file)
        store.add(record())
        store.add(record(proofId = proofId))

        assertEquals(proofId, store.recordForProofId(proofId)?.proofId)
        assertNull(store.recordForProofId(UUID.randomUUID()))
    }

    @Test
    fun aMissingFileStartsEmptyWithoutThrowing() {
        val file = File(tempFolder.root, "does-not-exist.json")

        assertTrue(SelfProofRecordStore(file).records.isEmpty())
    }

    @Test
    fun aCorruptFileIsNotOverwrittenBySubsequentSaves() {
        val file = File(tempFolder.root, "self-proofs.json")
        file.writeText("not valid json{{{")

        val store = SelfProofRecordStore(file)
        assertTrue(store.records.isEmpty())
        assertTrue(store.isPersistenceSuspended)

        store.add(record())

        assertEquals("not valid json{{{", file.readText())
    }
}

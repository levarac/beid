package org.levarac.beid.persistence

import java.io.File
import java.util.UUID
import org.levarac.beid.sensing.SensingRecoverableSignature
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.junit.Rule
import org.junit.rules.TemporaryFolder

/**
 * On-device JSON store for completed wallet-binding records — same pattern
 * as iOS's `BindingRecordStore` (flat JSON, no server call, atomic write).
 */
class BindingRecordStoreTest {
    @get:Rule
    val tempFolder = TemporaryFolder()

    private fun record(proofId: UUID = UUID.randomUUID(), eventCode: String = "TEST-EVENT") = BindingRecord(
        proofId = proofId,
        eventCode = eventCode,
        walletAddress = "0x14791697260e4c9a71f18484c9f997b308e59325",
        eventSigningPublicKey = byteArrayOf(0x02, 0xAB.toByte()),
        ownerPublicKey = byteArrayOf(0x03, 0x11),
        chainId = 1,
        nonce = byteArrayOf(0x00, 0x01),
        issuedAt = "2026-07-30T09:00:00Z",
        walletSignatureHex = "0x" + "0a".repeat(65),
        deviceSignature = SensingRecoverableSignature(r = ByteArray(32) { 0x01 }, s = ByteArray(32) { 0x02 }, v = 0),
    )

    @Test
    fun addPersistsAndANewInstanceLoadsItBack() {
        val file = File(tempFolder.root, "binding-records-v2.json")
        val original = record()

        BindingRecordStore(file).add(original)
        val reloaded = BindingRecordStore(file)

        assertEquals(listOf(original), reloaded.records)
    }

    @Test
    fun recordForProofIdFindsTheFirstMatch() {
        val file = File(tempFolder.root, "binding-records-v2.json")
        val proofId = UUID.randomUUID()
        val store = BindingRecordStore(file)
        store.add(record())
        store.add(record(proofId = proofId))

        assertEquals(proofId, store.recordForProofId(proofId)?.proofId)
        assertNull(store.recordForProofId(UUID.randomUUID()))
    }

    @Test
    fun aMissingFileStartsEmptyWithoutThrowing() {
        val file = File(tempFolder.root, "does-not-exist.json")

        assertTrue(BindingRecordStore(file).records.isEmpty())
    }

    @Test
    fun aCorruptFileIsNotOverwrittenBySubsequentSaves() {
        val file = File(tempFolder.root, "binding-records-v2.json")
        file.writeText("not valid json{{{")

        val store = BindingRecordStore(file)
        assertTrue(store.records.isEmpty(), "a corrupt file must not populate in-memory records")
        assertTrue(store.isPersistenceSuspended)

        store.add(record())

        assertEquals("not valid json{{{", file.readText(), "the original corrupt bytes must survive verbatim, never be silently destroyed by a later save")
    }
}

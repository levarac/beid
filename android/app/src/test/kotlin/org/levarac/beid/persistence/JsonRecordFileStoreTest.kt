package org.levarac.beid.persistence

import java.io.File
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Rule
import org.junit.rules.TemporaryFolder

/**
 * Exercises [JsonRecordFileStore.updateRecord] directly — the mutation
 * capability [BindingRecordStore]/[SelfProofRecordStore] never needed (their
 * records are write-once), added for [ProofRecordStore] whose records change
 * in place (growing `peersVerified`, later-set signature status).
 */
class JsonRecordFileStoreTest {
    @get:Rule
    val tempFolder = TemporaryFolder()

    private data class TestRecord(val id: String, val value: Int)

    private fun store(file: File) = JsonRecordFileStore(
        file = file,
        schemaVersion = 1,
        toJson = { record: TestRecord ->
            buildJsonObject {
                put("id", record.id)
                put("value", record.value)
            }
        },
        fromJson = { json: JsonObject ->
            TestRecord(
                id = json.getValue("id").jsonPrimitive.content,
                value = json.getValue("value").jsonPrimitive.int,
            )
        },
    )

    @Test
    fun failedUpdateDoesNotPublishAnUnpersistedReceiptOrValue() {
        val file = File(tempFolder.root, "test-records.json")
        val store = store(file)
        store.addRecord(TestRecord("a", 1))
        val saved = file.readBytes()
        assertTrue(file.delete())
        assertTrue(file.mkdir())
        File(file, "occupied").writeText("force atomic replacement failure")

        assertFailsWith<IOException> {
            store.updateRecord({ it.id == "a" }, { it.copy(value = 99) })
        }
        assertEquals(listOf(TestRecord("a", 1)), store.records,
            "a failed durable write must not expose a receipt/value as saved")

        assertTrue(File(file, "occupied").delete())
        assertTrue(file.delete())
        file.writeBytes(saved)
        assertEquals(store(file).records, store.records)
        assertTrue(store.updateRecord({ it.id == "a" }, { it.copy(value = 99) }))
        assertEquals(listOf(TestRecord("a", 99)), store(file).records)
    }

    @Test
    fun failedAddDoesNotPublishOrDuplicateAnUnpersistedRecord() {
        val file = File(tempFolder.root, "test-records.json")
        val store = store(file)
        assertTrue(file.mkdir())
        File(file, "occupied").writeText("force atomic replacement failure")
        assertFailsWith<IOException> { store.addRecord(TestRecord("a", 1)) }
        assertEquals(emptyList(), store.records)
        assertTrue(File(file, "occupied").delete())
        assertTrue(file.delete())
        store.addRecord(TestRecord("a", 1))
        assertEquals(listOf(TestRecord("a", 1)), store(file).records)
    }

    @Test
    fun updateRecordReplacesTheFirstMatchAndPersistsIt() {
        val file = File(tempFolder.root, "test-records.json")
        val store = store(file)
        store.addRecord(TestRecord(id = "a", value = 1))
        store.addRecord(TestRecord(id = "b", value = 2))

        val didUpdate = store.updateRecord(
            predicate = { it.id == "b" },
            transform = { it.copy(value = 20) },
        )

        assertTrue(didUpdate)
        assertEquals(listOf(TestRecord("a", 1), TestRecord("b", 20)), store.records)
    }

    @Test
    fun updateRecordPersistsSoAFreshInstanceReloadsTheUpdatedValue() {
        val file = File(tempFolder.root, "test-records.json")
        store(file).addRecord(TestRecord(id = "a", value = 1))
        store(file).updateRecord(predicate = { it.id == "a" }, transform = { it.copy(value = 99) })

        val reloaded = store(file)

        assertEquals(listOf(TestRecord("a", 99)), reloaded.records)
    }

    @Test
    fun updateRecordIsANoOpWhenNothingMatches() {
        val file = File(tempFolder.root, "test-records.json")
        val store = store(file)
        store.addRecord(TestRecord(id = "a", value = 1))

        val didUpdate = store.updateRecord(
            predicate = { it.id == "does-not-exist" },
            transform = { it.copy(value = 999) },
        )

        assertFalse(didUpdate)
        assertEquals(listOf(TestRecord("a", 1)), store.records)
    }

    @Test
    fun updateRecordIsANoOpWhenPersistenceIsSuspended() {
        val file = File(tempFolder.root, "test-records.json")
        file.writeText("not valid json{{{")
        val store = store(file)
        assertTrue(store.isPersistenceSuspended)

        val didUpdate = store.updateRecord(
            predicate = { true },
            transform = { it.copy(value = 999) },
        )

        assertFalse(didUpdate)
        assertEquals(
            "not valid json{{{",
            file.readText(),
            "a suspended store must never overwrite bytes it never captured",
        )
    }
}

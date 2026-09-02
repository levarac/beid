package org.levarac.beid.ui.screens

import java.io.File
import java.time.Instant
import java.util.UUID
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.persistence.ProofRecordStore

/**
 * Unit tests for [RecordsViewModel] against a real [ProofRecordStore]
 * backed by a temp file — no fake needed, the store itself is a thin JVM
 * class, same choice [ProofRecordStoreTest] makes.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RecordsViewModelTest {
    @get:Rule
    val tempFolder = TemporaryFolder()

    private val testDispatcher = StandardTestDispatcher()

    @BeforeTest
    fun setUp() {
        Dispatchers.setMain(testDispatcher)
    }

    @AfterTest
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun store() = ProofRecordStore(File(tempFolder.root, "proof-records-v1.json"))

    private fun record(eventCode: String, createdAt: Instant, peersVerified: Int = 1) = ProofRecord(
        id = UUID.randomUUID(),
        eventCode = eventCode,
        createdAt = createdAt,
        peersVerified = peersVerified,
    )

    @Test
    fun recordsAreSortedReverseChronological() = runTest {
        val store = store()
        store.add(record("OLD", Instant.parse("2026-01-01T00:00:00Z")))
        store.add(record("NEW", Instant.parse("2026-06-01T00:00:00Z")))
        store.add(record("MID", Instant.parse("2026-03-01T00:00:00Z")))

        val viewModel = RecordsViewModel(store)
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(listOf("NEW", "MID", "OLD"), viewModel.records.value.map { it.eventCode })
    }

    @Test
    fun recordsUpdatesReactivelyWhenTheStoreChanges() = runTest {
        val store = store()
        val viewModel = RecordsViewModel(store)
        testDispatcher.scheduler.advanceUntilIdle()
        assertEquals(emptyList(), viewModel.records.value)

        store.add(record("NEW", Instant.parse("2026-06-01T00:00:00Z")))
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(listOf("NEW"), viewModel.records.value.map { it.eventCode })
    }
}

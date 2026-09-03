package org.levarac.beid.ui.screens

import java.io.File
import java.time.Instant
import java.util.UUID
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
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
 * Unit tests for [RecordDetailViewModel] against a real [ProofRecordStore]
 * backed by a temp file — same choice [RecordsViewModelTest] makes.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RecordDetailViewModelTest {
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

    private fun record(eventCode: String, id: UUID = UUID.randomUUID()) = ProofRecord(
        id = id,
        eventCode = eventCode,
        createdAt = Instant.parse("2026-01-01T00:00:00Z"),
        peersVerified = 1,
    )

    @Test
    fun exposesTheRecordMatchingTheGivenId() = runTest {
        val store = store()
        val target = record("TARGET")
        val other = record("OTHER")
        store.add(other)
        store.add(target)

        val viewModel = RecordDetailViewModel(store, target.id)
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals("TARGET", viewModel.record.value?.eventCode)
    }

    @Test
    fun exposesNullWhenNoRecordMatchesTheGivenId() = runTest {
        val store = store()
        store.add(record("OTHER"))

        val viewModel = RecordDetailViewModel(store, UUID.randomUUID())
        testDispatcher.scheduler.advanceUntilIdle()

        assertNull(viewModel.record.value)
    }

    @Test
    fun recordUpdatesReactivelyWhenTheStoreChangesItsSignatureState() = runTest {
        val store = store()
        val target = record("TARGET")
        store.add(target)

        val viewModel = RecordDetailViewModel(store, target.id)
        testDispatcher.scheduler.advanceUntilIdle()
        assertEquals(false, viewModel.record.value?.hasSelfProof)

        store.updateSignatureState(target.id, hasSelfProof = true, hasBinding = false)
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(true, viewModel.record.value?.hasSelfProof)
    }
}

package org.levarac.beid.ui.screens

import java.io.File
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import kotlin.test.assertEquals
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.persistence.ProofRecordStore

@OptIn(ExperimentalCoroutinesApi::class)
class TodaySummaryViewModelTest {
    @get:Rule
    val tempFolder = TemporaryFolder()

    private val testDispatcher = StandardTestDispatcher()
    private val clock = Clock.fixed(Instant.parse("2026-09-04T12:00:00Z"), ZoneOffset.UTC)

    @Before
    fun setUp() {
        Dispatchers.setMain(testDispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun countsOnlyRecordsInTheNativeResolvedCurrentDayThroughTheSharedRollup() {
        val records = listOf(
            record("YESTERDAY", "2026-09-03T23:59:59.999Z"),
            record("TODAY_ONE", "2026-09-04T00:00:00Z"),
            record("TODAY_TWO", "2026-09-04T11:00:00Z"),
            record("TOMORROW", "2026-09-05T00:00:00Z"),
        )

        assertEquals(2, todaySummaryRecordCount(records, clock, ZoneOffset.UTC))
    }

    @Test
    fun zeroRecordDayHasZeroCount() {
        assertEquals(0, todaySummaryRecordCount(emptyList(), clock, ZoneOffset.UTC))
    }

    @Test
    fun viewModelReadsTheSharedRollupFromTheProductionRecordStore() = runTest {
        val store = ProofRecordStore(File(tempFolder.root, "proof-records-v1.json"))
        store.add(record("YESTERDAY", "2026-09-03T23:59:59.999Z"))
        store.add(record("TODAY", "2026-09-04T00:00:00Z"))

        val viewModel = TodaySummaryViewModel(store, clock, ZoneOffset.UTC)
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(1, viewModel.recordCount.value)
    }

    private fun record(eventCode: String, createdAt: String) = ProofRecord(
        id = UUID.randomUUID(),
        eventCode = eventCode,
        createdAt = Instant.parse(createdAt),
        peersVerified = 0,
    )
}

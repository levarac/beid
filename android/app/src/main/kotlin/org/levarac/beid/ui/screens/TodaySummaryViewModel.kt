package org.levarac.beid.ui.screens

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import java.time.Clock
import java.time.ZoneId
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.shared.aggregation.addDayRollupRecord
import org.levarac.beid.shared.aggregation.createDayRollupInput
import org.levarac.beid.shared.aggregation.dayRollupWindow
import org.levarac.beid.shared.aggregation.rollupRecordsForDay

/**
 * Resolves the device's current calendar-day boundary, then delegates the
 * actual half-open-window membership decision to shared's day-rollup API.
 * Android owns the timezone effect; shared remains the only implementation
 * that decides which record timestamps fall within the supplied window.
 */
internal fun todaySummaryRecordCount(
    records: List<ProofRecord>,
    clock: Clock = Clock.systemDefaultZone(),
    zoneId: ZoneId = clock.zone,
): Int {
    val today = clock.instant().atZone(zoneId).toLocalDate()
    val start = today.atStartOfDay(zoneId).toInstant().toEpochMilli()
    val end = today.plusDays(1).atStartOfDay(zoneId).toInstant().toEpochMilli()
    val window = requireNotNull(dayRollupWindow(start, end))
    val input = createDayRollupInput()
    records.forEachIndexed { index, record ->
        addDayRollupRecord(input, index, record.createdAt.toEpochMilli())
    }
    return rollupRecordsForDay(input, window).recordCount
}

class TodaySummaryViewModel(
    proofRecordStore: ProofRecordStore,
    private val clock: Clock = Clock.systemDefaultZone(),
    private val zoneId: ZoneId = clock.zone,
) : ViewModel() {
    private val _recordCount = MutableStateFlow(
        todaySummaryRecordCount(proofRecordStore.recordsFlow.value, clock, zoneId),
    )
    val recordCount: StateFlow<Int> = _recordCount.asStateFlow()

    init {
        viewModelScope.launch {
            proofRecordStore.recordsFlow.collect { records ->
                _recordCount.value = todaySummaryRecordCount(records, clock, zoneId)
            }
        }
    }

    class Factory(private val proofRecordStore: ProofRecordStore) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            TodaySummaryViewModel(proofRecordStore) as T
    }
}

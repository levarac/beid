package org.levarac.beid.ui.screens

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.persistence.ProofRecordStore

/**
 * Presentation layer over [ProofRecordStore] for [RecordsScreen] — same
 * thin-layer shape as [EventJoinViewModel]/[AccountViewModel]: republishes
 * [ProofRecordStore.recordsFlow], sorted reverse-chronological by
 * [ProofRecord.createdAt] (newest first), the ordering [RecordsScreen]'s
 * flat list expects (beid#121; no event grouping — see [RecordsScreen]'s
 * kdoc).
 */
class RecordsViewModel(proofRecordStore: ProofRecordStore) : ViewModel() {
    // TODO(beid#341/#122): merge canonical ledger windows when the detail model can represent them.
    private val _records = MutableStateFlow(sortedByRecency(proofRecordStore.recordsFlow.value))
    val records: StateFlow<List<ProofRecord>> = _records.asStateFlow()

    init {
        viewModelScope.launch {
            proofRecordStore.recordsFlow.collect { records -> _records.value = sortedByRecency(records) }
        }
    }

    private fun sortedByRecency(records: List<ProofRecord>): List<ProofRecord> =
        records.sortedByDescending { it.createdAt }

    class Factory(private val proofRecordStore: ProofRecordStore) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = RecordsViewModel(proofRecordStore) as T
    }
}

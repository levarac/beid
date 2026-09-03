package org.levarac.beid.ui.screens

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.persistence.ProofRecordStore

/**
 * Presentation layer over [ProofRecordStore] for [RecordDetailScreen] — same
 * thin-layer shape as [RecordsViewModel], but republishes the single
 * [ProofRecord] matching [recordId] instead of the whole list, so an
 * in-progress signature-state change (self-proof/binding recorded while this
 * screen is open) is reflected live, matching the reason [RecordsViewModel]
 * is already reactive rather than a one-shot read.
 *
 * [record] is `null` both transiently-never (the initial value is read
 * synchronously from [ProofRecordStore.recordsFlow]'s current value, the
 * same source [RecordsViewModel] reads its own initial value from) and
 * persistently when [recordId] does not match any stored record — this app
 * never deletes records, so that should not normally happen, but a
 * stale/bad id must not crash [RecordDetailRoute]; see its own doc comment
 * for how it handles a permanently-`null` [record].
 */
class RecordDetailViewModel(proofRecordStore: ProofRecordStore, recordId: UUID) : ViewModel() {
    private val _record = MutableStateFlow(proofRecordStore.recordsFlow.value.find { it.id == recordId })
    val record: StateFlow<ProofRecord?> = _record.asStateFlow()

    init {
        viewModelScope.launch {
            proofRecordStore.recordsFlow.collect { records -> _record.value = records.find { it.id == recordId } }
        }
    }

    class Factory(
        private val proofRecordStore: ProofRecordStore,
        private val recordId: UUID,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            RecordDetailViewModel(proofRecordStore, recordId) as T
    }
}

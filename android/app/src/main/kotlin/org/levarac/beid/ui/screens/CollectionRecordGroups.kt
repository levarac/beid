package org.levarac.beid.ui.screens

import java.util.UUID
import org.levarac.beid.persistence.ProofRecord
import org.levarac.parallax.collection.EventGroupingRecord
import org.levarac.parallax.collection.EventRecordGroup
import org.levarac.parallax.collection.homeRecordGroups

/** Native metadata adapter only: identity, ordering, and active exclusion are shared decisions. */
internal fun homeProofRecordGroups(
    records: List<ProofRecord>,
    activeEventCode: String?,
): List<List<ProofRecord>> {
    val byId = records.associateBy { it.id.toString() }
    return homeRecordGroups(records.map { record ->
        EventGroupingRecord(
            recordId = record.id.toString(),
            eventCode = record.eventCode,
            recordedAtEpochSeconds = record.createdAt.epochSecond.toDouble() + record.createdAt.nano / 1e9,
        )
    }, activeEventCode).map { group -> group.nativeRecords(byId) }
}

/** Re-resolve an event list from current store state, keeping absent identities as singleton groups. */
internal fun proofRecordsForGroup(records: List<ProofRecord>, anchorId: UUID): List<ProofRecord> =
    homeProofRecordGroups(records, activeEventCode = null).firstOrNull { group ->
        group.any { it.id == anchorId }
    }.orEmpty()

private fun EventRecordGroup.nativeRecords(byId: Map<String, ProofRecord>): List<ProofRecord> =
    records.map { byId.getValue(it.recordId) }

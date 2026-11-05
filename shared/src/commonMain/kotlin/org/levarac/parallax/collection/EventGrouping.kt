package org.levarac.parallax.collection

import org.levarac.beid.shared.event.normalizedEventCodeOrNull

/**
 * Native record metadata for display grouping; no storage or presentation state.
 * [recordId] is the native record's stable, unique ID. Recording dates use epoch
 * seconds so an adapter can preserve iOS Date's subsecond precision.
 */
public class EventGroupingRecord public constructor(
    public val recordId: String,
    public val eventCode: String?,
    public val recordedAtEpochSeconds: Double,
)

/** A non-empty group, containing the original metadata in display order. */
public class EventRecordGroup internal constructor(
    public val records: List<EventGroupingRecord>,
)

/**
 * iOS EventGrouping.groups(from:) oracle: group by the shared join-path event
 * code normalizer, preserving first appearance and input order within groups.
 * Missing or unnormalizable codes use their record ID as a singleton identity,
 * in a separate namespace from event codes. No names or identities are inferred;
 * the supplied records and their stored codes are left untouched.
 */
public fun groupRecordsByEvent(records: List<EventGroupingRecord>): List<EventRecordGroup> =
    records.groupBy { record ->
        val eventKey = record.eventCode?.let(::normalizedEventCodeOrNull)
        if (eventKey == null) false to record.recordId else true to eventKey
    }.values.map { EventRecordGroup(records = it.toList()) }

/**
 * iOS EventGrouping.homeGroups(from:activeEventCode:) oracle: recording date
 * descending, with input position breaking equal-date ties, then ordinary event
 * grouping. Exclude the active event's entire group, including older sessions.
 * A missing or unnormalizable active code excludes nothing.
 */
public fun homeRecordGroups(
    records: List<EventGroupingRecord>,
    activeEventCode: String?,
): List<EventRecordGroup> {
    val dated = records.withIndex().sortedWith(
        compareByDescending<IndexedValue<EventGroupingRecord>> { it.value.recordedAtEpochSeconds }
            .thenBy { it.index },
    ).map { it.value }
    val activeKey = activeEventCode?.let(::normalizedEventCodeOrNull)
    return groupRecordsByEvent(dated).filter { group ->
        activeKey == null || group.records.first().eventCode?.let(::normalizedEventCodeOrNull) != activeKey
    }
}

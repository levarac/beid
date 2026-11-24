package org.levarac.parallax.collection

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Oracle: ios/Beid/Models/EventGrouping.swift and BeidTests/EventGroupingTests.swift. */
class EventGroupingTest {
    @Test
    fun groupsKeepFirstAppearanceAndInputSessionOrderAcrossSessions() {
        val records = listOf(record("a-old", "A", 100.0), record("b", "B", 300.0), record("a-new", "A", 400.0))

        // groups(from:) preserves input order; only homeGroups sorts by date.
        assertEquals(listOf(listOf("a-old", "a-new"), listOf("b")), ids(groupRecordsByEvent(records)))
    }

    @Test
    fun groupsUseTheJoinPathsTrimmedCaseFoldedEventCode() {
        val records = listOf(record("upper", " ETHTOKYO "), record("other", "B"), record("lower", "ethtokyo"))

        assertEquals(listOf(listOf("upper", "lower"), listOf("other")), ids(groupRecordsByEvent(records)))
        assertEquals(" ETHTOKYO ", records[0].eventCode)
    }

    @Test
    fun missingAndUnnormalizableIdentityRecordsRemainSeparate() {
        val records = listOf(
            record("nil-1", null), record("nil-2", null), record("empty", ""),
            record("blank", " \t\n"), record("real", "A"),
        )

        assertEquals(records.map { listOf(it.recordId) }, ids(groupRecordsByEvent(records)))
    }

    @Test
    fun homeSortsByRecordedDateAndExcludesEverySessionOfTheActiveEvent() {
        val records = listOf(
            record("older", "OLDER", 200.0), record("active-old", "ACTIVE", 100.0),
            record("newer", "NEWER", 300.0), record("active-new", "active", 400.0),
        )

        assertEquals(listOf(listOf("newer"), listOf("older")), ids(homeRecordGroups(records, " active ")))
        assertEquals(
            listOf(listOf("active-new", "active-old"), listOf("newer"), listOf("older")),
            ids(homeRecordGroups(records, null)),
        )
    }

    @Test
    fun homeKeepsMissingIdentityRecordsSeparateAndOrdersThemByDate() {
        val records = listOf(record("first", null, 100.0), record("second", null, 200.0))

        assertEquals(listOf(listOf("second"), listOf("first")), ids(homeRecordGroups(records, "ACTIVE")))
    }

    @Test
    fun identicalDatesPreserveInputOrderAcrossGroupsAndWithinEachGroup() {
        // Deliberately reverse the IDs: Home uses input position, not record ID, as its tie-break.
        val records = listOf(
            record("z", "A", 100.0), record("y", "B", 100.0),
            record("x", "a", 100.0), record("w", null, 100.0), record("v", null, 100.0),
        )

        assertEquals(listOf(listOf("z", "x"), listOf("y"), listOf("w"), listOf("v")), ids(homeRecordGroups(records, null)))
    }

    @Test
    fun homeRetainsSubsecondDateOrdering() {
        val records = listOf(record("earlier", "A", 100.125), record("later", "B", 100.25))

        assertEquals(listOf(listOf("later"), listOf("earlier")), ids(homeRecordGroups(records, null)))
    }

    @Test
    fun missingOrBlankActiveIdentityDoesNotHideAnyGroup() {
        val records = listOf(record("legacy", null), record("blank", " "), record("real", "A"))

        for (active in listOf(null, "", " \t", "absent")) {
            assertEquals(listOf(listOf("legacy"), listOf("blank"), listOf("real")), ids(homeRecordGroups(records, active)))
        }
    }

    @Test
    fun groupingDoesNotApplyAdditionalUnicodeFolding() {
        val records = listOf(record("ascii", "A"), record("fullwidth", "Ａ"))

        assertEquals(listOf(listOf("ascii"), listOf("fullwidth")), ids(groupRecordsByEvent(records)))
    }

    @Test
    fun emptyAndSingleRecordInputsHaveNoEmptyGroups() {
        assertTrue(groupRecordsByEvent(emptyList()).isEmpty())
        assertTrue(homeRecordGroups(emptyList(), "A").isEmpty())
        assertEquals(listOf(listOf("solo")), ids(groupRecordsByEvent(listOf(record("solo", "A")))))
    }

    @Test
    fun homeLeavesTheInputOrderAndRecordMetadataUntouched() {
        val records = listOf(record("old", " A ", 100.0), record("new", "a", 200.0))
        val group = homeRecordGroups(records, null).single()

        assertEquals(listOf("new", "old"), group.records.map { it.recordId })
        assertEquals(listOf("old", "new"), records.map { it.recordId })
        assertEquals(listOf("a", " A "), group.records.map { it.eventCode })
        assertEquals(listOf(200.0, 100.0), group.records.map { it.recordedAtEpochSeconds })
    }

    private fun record(id: String, code: String?, date: Double = 100.0) =
        EventGroupingRecord(recordId = id, eventCode = code, recordedAtEpochSeconds = date)

    private fun ids(groups: List<EventRecordGroup>): List<List<String>> =
        groups.map { group -> group.records.map { it.recordId } }
}

package org.levarac.beid.shared.event

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private const val EVENT_A = "00000000000000aa"
private const val EVENT_B = "00000000000000bb"

private fun hashForIndex(index: Int): String = index.toString(16).padStart(16, '0')

class EventInfoStoreTest {
    @Test
    fun newStoreRetainsNothingAndOmitsNothing() {
        val store = createEventInfoStore()
        assertEquals(0, store.retainedEventCount)
        assertFalse(store.hasOmittedEvents)
        assertEquals(0, eventInfoCandidates(store, createEventDefinitionInput()).candidateCount)
    }

    @Test
    fun recordedHintBecomesAnUnmatchedCandidate() {
        val store = createEventInfoStore()
        assertTrue(recordEventInfoHint(store, EVENT_A, windowIndex = 7L))

        val candidates = eventInfoCandidates(store, createEventDefinitionInput())
        assertEquals(1, candidates.candidateCount)

        val candidate = assertNotNull(candidates.candidateAt(0))
        assertEquals(EVENT_A, candidate.eventCodeHashHex)
        assertEquals(7L, candidate.firstSeenWindowIndex)
        assertEquals(7L, candidate.lastSeenWindowIndex)
        assertEquals(1, candidate.observationCount)
        assertFalse(candidate.isDefinitionMatched)
        assertNull(candidate.definition)
        assertNull(candidate.displayName)
    }

    /**
     * The carve-out, stated as a vector.
     *
     * No number of observations may turn an unknowable relay count into a zero.
     * A zero would claim that nobody relayed the event; the truth is that
     * Barnard 0.3.0 cannot tell us either way.
     */
    @Test
    fun relayCountIsAbsentRatherThanZeroNoMatterHowMuchIsObserved() {
        val store = createEventInfoStore()
        repeat(50) { assertTrue(recordEventInfoHint(store, EVENT_A, windowIndex = it.toLong())) }

        val candidate = assertNotNull(
            eventInfoCandidates(store, createEventDefinitionInput()).candidateAt(0),
        )
        assertNull(candidate.relayCount)
    }

    @Test
    fun candidateWithNoMatchingDefinitionIsStillReturned() {
        val store = createEventInfoStore()
        assertTrue(recordEventInfoHint(store, EVENT_A, windowIndex = 1L))
        assertTrue(recordEventInfoHint(store, EVENT_B, windowIndex = 1L))

        val definitions = createEventDefinitionInput()
        assertTrue(addEventDefinition(definitions, EVENT_A, "ETHTokyo 2026", 0L, 100L))

        val candidates = eventInfoCandidates(store, definitions)
        assertEquals(2, candidates.candidateCount)
        assertTrue(assertNotNull(candidates.candidateAt(0)).isDefinitionMatched)
        assertFalse(assertNotNull(candidates.candidateAt(1)).isDefinitionMatched)
    }

    @Test
    fun definitionIsJoinedAtReadTimeEvenWhenItArrivesAfterTheHint() {
        val store = createEventInfoStore()
        assertTrue(recordEventInfoHint(store, EVENT_A, windowIndex = 3L))

        val definitions = createEventDefinitionInput()
        assertTrue(addEventDefinition(definitions, EVENT_A, "ETHTokyo 2026", 100L, 110L))

        val candidate = assertNotNull(eventInfoCandidates(store, definitions).candidateAt(0))
        assertTrue(candidate.isDefinitionMatched)
        assertEquals("ETHTokyo 2026", candidate.displayName)

        val facts = assertNotNull(candidate.definition)
        assertEquals(100L, facts.eninStart)
        assertEquals(110L, facts.eninEnd)
    }

    @Test
    fun candidatesAreOrderedByHashAscending() {
        val store = createEventInfoStore()
        assertTrue(recordEventInfoHint(store, EVENT_B, windowIndex = 1L))
        assertTrue(recordEventInfoHint(store, EVENT_A, windowIndex = 1L))

        val candidates = eventInfoCandidates(store, createEventDefinitionInput())
        assertEquals(EVENT_A, assertNotNull(candidates.candidateAt(0)).eventCodeHashHex)
        assertEquals(EVENT_B, assertNotNull(candidates.candidateAt(1)).eventCodeHashHex)
    }

    @Test
    fun firstAndLastWindowDoNotDependOnArrivalOrder() {
        val ascending = createEventInfoStore()
        listOf(4L, 9L, 6L).forEach { assertTrue(recordEventInfoHint(ascending, EVENT_A, it)) }

        val descending = createEventInfoStore()
        listOf(6L, 9L, 4L).forEach { assertTrue(recordEventInfoHint(descending, EVENT_A, it)) }

        listOf(ascending, descending).forEach { store ->
            val candidate = assertNotNull(
                eventInfoCandidates(store, createEventDefinitionInput()).candidateAt(0),
            )
            assertEquals(4L, candidate.firstSeenWindowIndex)
            assertEquals(9L, candidate.lastSeenWindowIndex)
            assertEquals(3, candidate.observationCount)
        }
    }

    @Test
    fun hashCaseDoesNotSplitAnEventIntoTwoCandidates() {
        val store = createEventInfoStore()
        assertTrue(recordEventInfoHint(store, EVENT_A.uppercase(), windowIndex = 1L))
        assertTrue(recordEventInfoHint(store, EVENT_A, windowIndex = 2L))

        assertEquals(1, store.retainedEventCount)
        val candidate = assertNotNull(
            eventInfoCandidates(store, createEventDefinitionInput()).candidateAt(0),
        )
        assertEquals(EVENT_A, candidate.eventCodeHashHex)
        assertEquals(2, candidate.observationCount)
    }

    @Test
    fun definitionLookupIsCaseInsensitiveOnBothSides() {
        val store = createEventInfoStore()
        assertTrue(recordEventInfoHint(store, EVENT_A, windowIndex = 1L))

        val definitions = createEventDefinitionInput()
        assertTrue(addEventDefinition(definitions, EVENT_A.uppercase(), "ETHTokyo 2026", 0L, 100L))

        assertTrue(
            assertNotNull(eventInfoCandidates(store, definitions).candidateAt(0)).isDefinitionMatched,
        )
    }

    @Test
    fun malformedHintsAreRejectedAtTheBoundary() {
        val store = createEventInfoStore()
        assertFalse(recordEventInfoHint(store, "00000000000000a", windowIndex = 1L))
        assertFalse(recordEventInfoHint(store, "00000000000000aaa", windowIndex = 1L))
        assertFalse(recordEventInfoHint(store, "zzzzzzzzzzzzzzzz", windowIndex = 1L))
        assertFalse(recordEventInfoHint(store, EVENT_A, windowIndex = -1L))
        assertEquals(0, store.retainedEventCount)
    }

    /**
     * Barnard replaces an overflowed hint with an empty display name and an
     * empty event code hash. The hash shape check alone rejects it, so the
     * marker never becomes a candidate and no Barnard semantics are re-checked.
     */
    @Test
    fun barnardOverflowMarkerNeverBecomesACandidate() {
        val store = createEventInfoStore()
        assertFalse(recordEventInfoHint(store, "", windowIndex = 1L))
        assertEquals(0, store.retainedEventCount)
        assertFalse(store.hasOmittedEvents)
    }

    @Test
    fun retentionStopsAtThirtyTwoEventsAndSaysSo() {
        val store = createEventInfoStore()
        repeat(MAX_RETAINED_EVENT_COUNT) {
            assertTrue(recordEventInfoHint(store, hashForIndex(it), windowIndex = 1L))
        }
        assertEquals(MAX_RETAINED_EVENT_COUNT, store.retainedEventCount)
        assertFalse(store.hasOmittedEvents)

        assertFalse(recordEventInfoHint(store, hashForIndex(MAX_RETAINED_EVENT_COUNT), windowIndex = 1L))
        assertEquals(MAX_RETAINED_EVENT_COUNT, store.retainedEventCount)
        assertTrue(store.hasOmittedEvents)
    }

    @Test
    fun retainedEventsKeepAccumulatingAfterCapacityIsReached() {
        val store = createEventInfoStore()
        repeat(MAX_RETAINED_EVENT_COUNT) {
            assertTrue(recordEventInfoHint(store, hashForIndex(it), windowIndex = 1L))
        }
        assertFalse(recordEventInfoHint(store, hashForIndex(999), windowIndex = 1L))
        assertTrue(recordEventInfoHint(store, hashForIndex(0), windowIndex = 5L))

        val candidate = assertNotNull(
            eventInfoCandidates(store, createEventDefinitionInput()).candidateAt(0),
        )
        assertEquals(2, candidate.observationCount)
        assertEquals(5L, candidate.lastSeenWindowIndex)
    }

    @Test
    fun laterDefinitionForOneEventReplacesTheEarlierOne() {
        val store = createEventInfoStore()
        assertTrue(recordEventInfoHint(store, EVENT_A, windowIndex = 1L))

        val definitions = createEventDefinitionInput()
        assertTrue(addEventDefinition(definitions, EVENT_A, "Old name", 0L, 10L))
        assertTrue(addEventDefinition(definitions, EVENT_A, "New name", 20L, 30L))
        assertEquals(1, definitions.definitionCount)

        val candidate = assertNotNull(eventInfoCandidates(store, definitions).candidateAt(0))
        assertEquals("New name", candidate.displayName)
        assertEquals(20L, assertNotNull(candidate.definition).eninStart)
    }

    @Test
    fun rejectedDefinitionDoesNotEnterTheReadTimeSet() {
        val definitions = createEventDefinitionInput()
        assertFalse(addEventDefinition(definitions, EVENT_A, "ETHTokyo 2026", 30L, 20L))
        assertEquals(0, definitions.definitionCount)
    }
}

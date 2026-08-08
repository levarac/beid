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
        assertFalse(store.hasEvictedEvents)
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
        assertFalse(store.hasEvictedEvents)
    }

    private fun retainedHashes(store: EventInfoStore): Set<String> {
        val candidates = eventInfoCandidates(store, createEventDefinitionInput())
        return (0 until candidates.candidateCount)
            .map { assertNotNull(candidates.candidateAt(it)).eventCodeHashHex }
            .toSet()
    }

    @Test
    fun capacityEvictsTheLeastRecentlySeenEventRatherThanRefusingTheNewOne() {
        val store = createEventInfoStore()
        repeat(MAX_RETAINED_EVENT_COUNT) {
            assertTrue(recordEventInfoHint(store, hashForIndex(it), windowIndex = it.toLong()))
        }
        assertEquals(MAX_RETAINED_EVENT_COUNT, store.retainedEventCount)
        assertFalse(store.hasEvictedEvents)

        val newcomer = hashForIndex(999)
        assertTrue(recordEventInfoHint(store, newcomer, windowIndex = 500L))

        assertEquals(MAX_RETAINED_EVENT_COUNT, store.retainedEventCount)
        assertTrue(store.hasEvictedEvents)

        val retained = retainedHashes(store)
        assertTrue(retained.contains(newcomer))
        // hashForIndex(0) had the smallest lastSeenWindowIndex, so it goes first.
        assertFalse(retained.contains(hashForIndex(0)))
        assertTrue(retained.contains(hashForIndex(1)))
    }

    @Test
    fun evictionTiebreakIsDeterministicWhenLastSeenWindowsAreEqual() {
        val store = createEventInfoStore()
        repeat(MAX_RETAINED_EVENT_COUNT) {
            assertTrue(recordEventInfoHint(store, hashForIndex(it), windowIndex = 5L))
        }
        assertTrue(recordEventInfoHint(store, hashForIndex(999), windowIndex = 5L))

        val retained = retainedHashes(store)
        assertFalse(retained.contains(hashForIndex(0)))
        assertTrue(retained.contains(hashForIndex(1)))
        assertTrue(retained.contains(hashForIndex(999)))
    }

    /**
     * The failure this eviction policy exists to prevent, as a vector.
     *
     * Barnard caps at 32 **and clears its whole retention set every 300 seconds**,
     * so it keeps reporting events indefinitely. A store that refuses at capacity
     * therefore goes permanently deaf: someone crosses a busy area, fills the
     * retention set with events they walked past, arrives at the event they came
     * for, and that one is the one silently dropped — while the candidate list
     * still looks perfectly healthy.
     */
    @Test
    fun theEventTheUserCameForSurvivesCrossingABusyArea() {
        val store = createEventInfoStore()
        repeat(MAX_RETAINED_EVENT_COUNT) {
            assertTrue(recordEventInfoHint(store, hashForIndex(it), windowIndex = it.toLong()))
        }

        val intended = "00000000000000ff"
        assertTrue(recordEventInfoHint(store, intended, windowIndex = 500L))

        val definitions = createEventDefinitionInput()
        assertTrue(addEventDefinition(definitions, intended, "ETHTokyo 2026", 400L, 600L))

        val candidates = eventInfoCandidates(store, definitions)
        val match = (0 until candidates.candidateCount)
            .map { assertNotNull(candidates.candidateAt(it)) }
            .single { it.eventCodeHashHex == intended }
        assertTrue(match.isDefinitionMatched)
        assertEquals("ETHTokyo 2026", match.displayName)
        assertTrue(isEventWindowOpen(assertNotNull(match.definition), atWindowIndex = 500L))
    }

    @Test
    fun resetClearsRetentionAndTheEvictionFlag() {
        val store = createEventInfoStore()
        repeat(MAX_RETAINED_EVENT_COUNT + 1) {
            assertTrue(recordEventInfoHint(store, hashForIndex(it), windowIndex = it.toLong()))
        }
        assertTrue(store.hasEvictedEvents)

        resetEventInfoStore(store)

        assertEquals(0, store.retainedEventCount)
        assertFalse(store.hasEvictedEvents)
        assertEquals(0, eventInfoCandidates(store, createEventDefinitionInput()).candidateCount)

        assertTrue(recordEventInfoHint(store, EVENT_A, windowIndex = 3L))
        assertEquals(1, store.retainedEventCount)
        val candidate = assertNotNull(
            eventInfoCandidates(store, createEventDefinitionInput()).candidateAt(0),
        )
        assertEquals(3L, candidate.firstSeenWindowIndex)
        assertEquals(1, candidate.observationCount)
    }

    @Test
    fun anEvictedEventReturningIsRecordedAfreshRatherThanResumingOldFacts() {
        val store = createEventInfoStore()
        repeat(MAX_RETAINED_EVENT_COUNT) {
            assertTrue(recordEventInfoHint(store, hashForIndex(it), windowIndex = it.toLong()))
        }
        assertTrue(recordEventInfoHint(store, hashForIndex(999), windowIndex = 500L))
        assertFalse(retainedHashes(store).contains(hashForIndex(0)))

        assertTrue(recordEventInfoHint(store, hashForIndex(0), windowIndex = 501L))
        val candidates = eventInfoCandidates(store, createEventDefinitionInput())
        val returned = (0 until candidates.candidateCount)
            .map { assertNotNull(candidates.candidateAt(it)) }
            .single { it.eventCodeHashHex == hashForIndex(0) }
        assertEquals(501L, returned.firstSeenWindowIndex)
        assertEquals(1, returned.observationCount)
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

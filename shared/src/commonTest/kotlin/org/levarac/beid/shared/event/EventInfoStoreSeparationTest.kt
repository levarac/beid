package org.levarac.beid.shared.event

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private const val EVENT_A = "00000000000000aa"
private const val EVENT_B = "00000000000000bb"
private const val EVENT_C = "00000000000000cc"

/**
 * Adversarial tests for one claim: **a supplied definition can change what a
 * candidate is judged to be, but can never change what the store recorded as
 * observed.**
 *
 * That claim is asserted in [eventInfoCandidates]'s doc comment, and a doc
 * comment is not evidence. These tests try to break it from every direction a
 * caller could reach, so a reviewer can check the separation by running
 * something rather than by re-reading the implementation and agreeing with it.
 */
class EventInfoStoreSeparationTest {
    private fun storeWithObservations(): EventInfoStore {
        val store = createEventInfoStore()
        assertTrue(recordEventInfoHint(store, EVENT_A, windowIndex = 4L))
        assertTrue(recordEventInfoHint(store, EVENT_A, windowIndex = 9L))
        assertTrue(recordEventInfoHint(store, EVENT_B, windowIndex = 6L))
        return store
    }

    private fun observedFacts(store: EventInfoStore, definitions: EventDefinitionInput): List<String> =
        (0 until eventInfoCandidates(store, definitions).candidateCount).map { index ->
            val candidate = assertNotNull(eventInfoCandidates(store, definitions).candidateAt(index))
            "${candidate.eventCodeHashHex}/${candidate.firstSeenWindowIndex}/" +
                "${candidate.lastSeenWindowIndex}/${candidate.observationCount}"
        }

    @Test
    fun hostileDefinitionSetLeavesObservedFactsByteForByteIdentical() {
        val store = storeWithObservations()
        val baseline = observedFacts(store, createEventDefinitionInput())

        val hostile = createEventDefinitionInput()
        // Definitions for events that were observed, for one that was not, with
        // windows nowhere near what was heard and a name designed to be shown.
        assertTrue(addEventDefinition(hostile, EVENT_A, "Not the real event", 9000L, 9999L))
        assertTrue(addEventDefinition(hostile, EVENT_B, "Also not real", 0L, 1L))
        assertTrue(addEventDefinition(hostile, EVENT_C, "Never heard at all", 0L, 9999L))

        assertEquals(baseline, observedFacts(store, hostile))
        assertEquals(baseline, observedFacts(store, createEventDefinitionInput()))
    }

    @Test
    fun definitionForAnUnobservedEventNeverCreatesACandidate() {
        val store = storeWithObservations()
        val definitions = createEventDefinitionInput()
        assertTrue(addEventDefinition(definitions, EVENT_C, "Never heard at all", 0L, 9999L))

        val candidates = eventInfoCandidates(store, definitions)
        assertEquals(2, candidates.candidateCount)
        assertEquals(EVENT_A, assertNotNull(candidates.candidateAt(0)).eventCodeHashHex)
        assertEquals(EVENT_B, assertNotNull(candidates.candidateAt(1)).eventCodeHashHex)
    }

    @Test
    fun definitionForOneEventDoesNotReachAnother() {
        val store = storeWithObservations()
        val definitions = createEventDefinitionInput()
        assertTrue(addEventDefinition(definitions, EVENT_A, "ETHTokyo 2026", 0L, 100L))

        val candidates = eventInfoCandidates(store, definitions)
        assertTrue(assertNotNull(candidates.candidateAt(0)).isDefinitionMatched)

        val untouched = assertNotNull(candidates.candidateAt(1))
        assertFalse(untouched.isDefinitionMatched)
        assertNull(untouched.displayName)
        assertNull(untouched.definition)
        assertEquals(6L, untouched.firstSeenWindowIndex)
    }

    @Test
    fun candidateMembershipAndOrderDoNotDependOnTheDefinitionSet() {
        val store = storeWithObservations()
        val empty = createEventDefinitionInput()
        val full = createEventDefinitionInput()
        assertTrue(addEventDefinition(full, EVENT_B, "B first alphabetically? no", 0L, 1L))
        assertTrue(addEventDefinition(full, EVENT_A, "ETHTokyo 2026", 0L, 100L))

        val withoutDefinitions = (0 until eventInfoCandidates(store, empty).candidateCount).map {
            assertNotNull(eventInfoCandidates(store, empty).candidateAt(it)).eventCodeHashHex
        }
        val withDefinitions = (0 until eventInfoCandidates(store, full).candidateCount).map {
            assertNotNull(eventInfoCandidates(store, full).candidateAt(it)).eventCodeHashHex
        }
        assertEquals(withoutDefinitions, withDefinitions)
    }

    @Test
    fun readingCandidatesDoesNotAdvanceOrAlterTheStore() {
        val store = storeWithObservations()
        val definitions = createEventDefinitionInput()
        assertTrue(addEventDefinition(definitions, EVENT_A, "ETHTokyo 2026", 0L, 100L))

        repeat(5) { eventInfoCandidates(store, definitions) }

        assertEquals(2, store.retainedEventCount)
        assertFalse(store.hasOmittedEvents)
        val candidate = assertNotNull(eventInfoCandidates(store, definitions).candidateAt(0))
        assertEquals(2, candidate.observationCount)
        assertEquals(4L, candidate.firstSeenWindowIndex)
        assertEquals(9L, candidate.lastSeenWindowIndex)
    }

    /**
     * A candidate handed to a caller is a snapshot, not a live view.
     *
     * If it aliased the store's mutable record, a card already on screen would
     * silently change its own facts when the next hint arrived.
     */
    @Test
    fun anAlreadyReturnedCandidateDoesNotChangeWhenNewHintsArrive() {
        val store = storeWithObservations()
        val candidate = assertNotNull(
            eventInfoCandidates(store, createEventDefinitionInput()).candidateAt(0),
        )
        assertEquals(2, candidate.observationCount)
        assertEquals(9L, candidate.lastSeenWindowIndex)

        assertTrue(recordEventInfoHint(store, EVENT_A, windowIndex = 40L))
        assertTrue(recordEventInfoHint(store, EVENT_A, windowIndex = 1L))

        assertEquals(2, candidate.observationCount)
        assertEquals(9L, candidate.lastSeenWindowIndex)
        assertEquals(4L, candidate.firstSeenWindowIndex)

        val refreshed = assertNotNull(
            eventInfoCandidates(store, createEventDefinitionInput()).candidateAt(0),
        )
        assertEquals(4, refreshed.observationCount)
        assertEquals(40L, refreshed.lastSeenWindowIndex)
        assertEquals(1L, refreshed.firstSeenWindowIndex)
    }

    @Test
    fun definitionsCannotInfluenceRetentionCapacityOrTheOmissionFlag() {
        val store = createEventInfoStore()
        val definitions = createEventDefinitionInput()
        repeat(MAX_RETAINED_EVENT_COUNT + 4) { index ->
            val hash = index.toString(16).padStart(16, '0')
            assertTrue(addEventDefinition(definitions, hash, "Definition $index", 0L, 9999L))
            recordEventInfoHint(store, hash, windowIndex = 1L)
        }

        assertEquals(MAX_RETAINED_EVENT_COUNT, store.retainedEventCount)
        assertTrue(store.hasOmittedEvents)
        assertEquals(
            MAX_RETAINED_EVENT_COUNT,
            eventInfoCandidates(store, definitions).candidateCount,
        )
    }

    /**
     * A definition can flip the time-window verdict, and that is the whole point
     * of the layer. The separation claim is that it stops there.
     */
    @Test
    fun definitionChangesTheVerdictWhileTheObservationStandsUnchanged() {
        val store = createEventInfoStore()
        assertTrue(recordEventInfoHint(store, EVENT_A, windowIndex = 50L))

        val truthful = createEventDefinitionInput()
        assertTrue(addEventDefinition(truthful, EVENT_A, "ETHTokyo 2026", 40L, 60L))
        val lying = createEventDefinitionInput()
        assertTrue(addEventDefinition(lying, EVENT_A, "ETHTokyo 2026", 900L, 999L))

        val truthfulCandidate = assertNotNull(eventInfoCandidates(store, truthful).candidateAt(0))
        val lyingCandidate = assertNotNull(eventInfoCandidates(store, lying).candidateAt(0))

        assertTrue(isEventWindowOpen(assertNotNull(truthfulCandidate.definition), 50L))
        assertFalse(isEventWindowOpen(assertNotNull(lyingCandidate.definition), 50L))

        assertEquals(50L, truthfulCandidate.firstSeenWindowIndex)
        assertEquals(50L, lyingCandidate.firstSeenWindowIndex)
        assertEquals(1, truthfulCandidate.observationCount)
        assertEquals(1, lyingCandidate.observationCount)
    }
}

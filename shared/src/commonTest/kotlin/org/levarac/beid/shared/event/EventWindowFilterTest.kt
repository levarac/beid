package org.levarac.beid.shared.event

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private const val EVENT_A = "0011223344556677"

private fun definition(eninStart: Long, eninEnd: Long): EventDefinitionFacts =
    assertNotNull(
        createEventDefinitionFacts(
            eventCodeHashHex = EVENT_A,
            displayName = "ETHTokyo 2026",
            eninStart = eninStart,
            eninEnd = eninEnd,
        ),
    )

class EventWindowFilterTest {
    @Test
    fun windowIsOpenAtItsFirstWindow() {
        assertTrue(isEventWindowOpen(definition(eninStart = 100L, eninEnd = 110L), atWindowIndex = 100L))
    }

    @Test
    fun windowIsOpenAtItsLastWindow() {
        assertTrue(isEventWindowOpen(definition(eninStart = 100L, eninEnd = 110L), atWindowIndex = 110L))
    }

    @Test
    fun windowIsOpenInsideTheRange() {
        assertTrue(isEventWindowOpen(definition(eninStart = 100L, eninEnd = 110L), atWindowIndex = 105L))
    }

    @Test
    fun windowIsClosedOneWindowBeforeItStarts() {
        assertFalse(isEventWindowOpen(definition(eninStart = 100L, eninEnd = 110L), atWindowIndex = 99L))
    }

    @Test
    fun windowIsClosedOneWindowAfterItEnds() {
        assertFalse(isEventWindowOpen(definition(eninStart = 100L, eninEnd = 110L), atWindowIndex = 111L))
    }

    @Test
    fun singleWindowEventIsOpenOnlyInThatWindow() {
        val single = definition(eninStart = 42L, eninEnd = 42L)
        assertTrue(isEventWindowOpen(single, atWindowIndex = 42L))
        assertFalse(isEventWindowOpen(single, atWindowIndex = 41L))
        assertFalse(isEventWindowOpen(single, atWindowIndex = 43L))
    }

    /**
     * The success criterion of this slice, stated as a vector.
     *
     * An event first heard before it starts must be judged closed then and open
     * later, from the same stored facts. Any implementation that freezes the
     * answer when the hint arrives fails this.
     */
    @Test
    fun eventHeardBeforeItStartsIsJudgedOpenOnceInsideTheWindow() {
        val store = createEventInfoStore()
        val firstHeardWindow = 90L
        assertTrue(recordEventInfoHint(store, EVENT_A, windowIndex = firstHeardWindow))

        val definitions = createEventDefinitionInput()
        assertTrue(
            addEventDefinition(
                input = definitions,
                eventCodeHashHex = EVENT_A,
                displayName = "ETHTokyo 2026",
                eninStart = 100L,
                eninEnd = 110L,
            ),
        )

        val candidate = assertNotNull(eventInfoCandidates(store, definitions).candidateAt(0))
        val facts = assertNotNull(candidate.definition)

        assertFalse(isEventWindowOpen(facts, atWindowIndex = firstHeardWindow))
        assertFalse(isEventWindowOpen(facts, atWindowIndex = 99L))
        assertTrue(isEventWindowOpen(facts, atWindowIndex = 100L))
        assertTrue(isEventWindowOpen(facts, atWindowIndex = 105L))
        assertFalse(isEventWindowOpen(facts, atWindowIndex = 111L))
    }

    @Test
    fun invertedRangeIsRejectedRatherThanNeverOpen() {
        assertNull(
            createEventDefinitionFacts(
                eventCodeHashHex = EVENT_A,
                displayName = "ETHTokyo 2026",
                eninStart = 110L,
                eninEnd = 100L,
            ),
        )
    }

    @Test
    fun negativeBoundsAreRejected() {
        assertNull(
            createEventDefinitionFacts(
                eventCodeHashHex = EVENT_A,
                displayName = "ETHTokyo 2026",
                eninStart = -1L,
                eninEnd = 100L,
            ),
        )
    }

    @Test
    fun malformedDefinitionInputIsRejected() {
        assertNull(createEventDefinitionFacts("00112233445566", "ETHTokyo 2026", 100L, 110L))
        assertNull(createEventDefinitionFacts(EVENT_A, "", 100L, 110L))
        assertNull(createEventDefinitionFacts(EVENT_A, "x".repeat(65), 100L, 110L))
    }
}

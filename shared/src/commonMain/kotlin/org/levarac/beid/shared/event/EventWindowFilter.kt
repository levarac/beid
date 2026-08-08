package org.levarac.beid.shared.event

/**
 * beid#139 layer 1: is [definition]'s event running in [atWindowIndex]?
 *
 * Pure, and deliberately time-free: the caller supplies the window to judge, so
 * the same candidate and the same definition yield different answers as the
 * event starts and ends. Storing this verdict when a hint arrives would leave an
 * event heard before its own start permanently marked as not running.
 *
 * Both bounds are **inclusive**, so a single-window event is open in exactly one
 * window and an event's last window is inside it. That reading is proposed, not
 * settled: the exact meaning of `eninEnd` belongs to the registry definition
 * whose decode is beid#108, and this predicate must follow it once it lands.
 *
 * Absence has no encoding here, on purpose. A candidate that matched no
 * definition has nothing to judge, which is a different answer from "closed",
 * and it is expressed by [EventCandidate.definition] being null rather than by a
 * third boolean state this signature would have to carry. Calling this predicate
 * at all requires already holding a definition.
 *
 * Applying the layer is the caller's decision, and skipping the call is how the
 * layer is disabled — beid#139 requires each of its three layers to be
 * independently disableable, so this function never filters anything itself.
 */
public fun isEventWindowOpen(
    definition: EventDefinitionFacts,
    atWindowIndex: Long,
): Boolean = atWindowIndex >= definition.eninStart && atWindowIndex <= definition.eninEnd

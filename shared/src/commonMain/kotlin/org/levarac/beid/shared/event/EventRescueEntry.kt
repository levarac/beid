package org.levarac.beid.shared.event

/**
 * What the event-join surface should be offering while the radio search is
 * running (beid#463).
 *
 * The rescue route — pasting a canonical open code — is the only way in for a
 * participant whose device cannot see the venue's B005 beacon at all, which is
 * exactly the participant who has no way of knowing that is what happened. So
 * the route cannot be something they have to already know is filed under
 * Account; after a bounded search that found nothing joinable, the surface has
 * to offer it.
 */
public enum class NearbyEventSearchOutcome {
    /** Keep searching, and do not yet suggest that something is wrong. */
    SEARCHING,

    /** Long enough with nothing joinable: offer the paste route. */
    RESCUE_ENTRY_OFFERED,
}

/**
 * How long the radio search runs before the surface offers the rescue route.
 *
 * A product timing, not a protocol value: nothing on the wire changes if it
 * moves. Twenty seconds is chosen to sit clearly past the point where a
 * working beacon in range would have been seen and clearly short of the point
 * where a participant standing in a doorway concludes the app is broken. It
 * lives here rather than in each host so the two cannot drift into offering
 * rescue at different moments, which would make a field report ambiguous about
 * which platform it described.
 */
public const val RESCUE_ENTRY_DELAY_SECONDS: Long = 20L

/**
 * The rule itself, as a pure function of the two things that decide it.
 *
 * [joinableCandidateCount] is *joinable* candidates, not observed ones. A
 * candidate that is merely visible — `RADIO_SELF_VERIFIED`, still unresolved,
 * no Event ID yet — renders as a card and cannot be joined, and a participant
 * looking at a screen of those is in precisely the dead end this route exists
 * for. Counting cards instead of joinable cards would withhold the rescue
 * route from them forever, and would do it silently, because the screen would
 * look busy.
 *
 * A negative or nonsensical elapsed value keeps [NearbyEventSearchOutcome.SEARCHING]:
 * a clock that went backwards is not evidence that a search has finished.
 */
public fun nearbyEventSearchOutcome(
    elapsedSecondsSinceSearchStarted: Long,
    joinableCandidateCount: Int,
): NearbyEventSearchOutcome = when {
    joinableCandidateCount > 0 -> NearbyEventSearchOutcome.SEARCHING
    elapsedSecondsSinceSearchStarted >= RESCUE_ENTRY_DELAY_SECONDS ->
        NearbyEventSearchOutcome.RESCUE_ENTRY_OFFERED
    else -> NearbyEventSearchOutcome.SEARCHING
}

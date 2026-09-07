package org.levarac.beid.sensing

import org.levarac.barnard.BarnardRelayDecision

/**
 * One spec 134 relay decision, in a form this app owns (beid#367).
 *
 * Purely diagnostic: it says whether this device is currently re-broadcasting
 * an event's information and why that started or stopped. It is deliberately
 * inert everywhere else. A relayed candidate is an ordinary card, its hop
 * count is never shown, and neither the hop nor the number of relays around it
 * is evidence about the event — spec 134 is explicit that relay volume means
 * nothing about an event's popularity, authenticity, or attendance.
 */
internal data class ParticipantRelayDecision(
    val decision: BarnardRelayDecision,
    /** `SHA256(signedEnvelope)`, which is already derivable from the wire. */
    val payloadDigestHex: String,
    val hop: Int,
    val reason: String,
)

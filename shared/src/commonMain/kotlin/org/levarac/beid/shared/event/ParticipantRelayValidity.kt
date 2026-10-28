package org.levarac.beid.shared.event

/** SDK-verified relay bounds adapted to the unsigned 32-bit native relay API. */
public class ParticipantRelayValidity internal constructor(
    public val validFromEnin: Long,
    public val validThroughEnin: Long,
    public val relayExpiresAtEnin: Long,
)

/**
 * Adapts numeric representation only; Barnard owns signature and window verification.
 *
 * B005 spec 122 encodes these fields as unsigned four-byte integers. For a wider
 * SDK value, retain the iOS boundary policy: clamp the validity end, zero-clamp
 * a negative start, and reject an unrepresentable start or signed expiry.
 * An accepted signed expiry is never changed. See docs/participant-relay-validity.md.
 */
public fun participantRelayValidity(
    validFromEnin: Long,
    validThroughEnin: Long,
    relayExpiresAtEnin: Long,
): ParticipantRelayValidity? {
    val start = maxOf(0L, validFromEnin)
    if (start > MAX_RELAY_ENIN || relayExpiresAtEnin !in 0L..MAX_RELAY_ENIN) return null
    return ParticipantRelayValidity(
        validFromEnin = start,
        validThroughEnin = validThroughEnin.coerceIn(0L, MAX_RELAY_ENIN),
        relayExpiresAtEnin = relayExpiresAtEnin,
    )
}

private const val MAX_RELAY_ENIN = 4_294_967_295L

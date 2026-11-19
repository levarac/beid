package org.levarac.beid.persistence

import java.util.UUID
import org.levarac.beid.shared.aggregation.addAggregationObservation
import org.levarac.beid.shared.aggregation.createAggregationObservationInput
import org.levarac.beid.shared.sigil.addSigilPresenceToken
import org.levarac.beid.shared.sigil.createSigilPresenceSession
import org.levarac.beid.shared.sigil.sigilPresenceTokensNeeded

/**
 * Writes a stored Sigil row for [proofId] through the production
 * [SigilPresenceStore.persist] path: [peers] detected-only display ids, peer
 * `p` seen in every window `w` of [windows] where `(p + w) % 3 != 0`. Tokens
 * are fixed so a render is reproducible. Detected only (presence 1), as on a
 * device: nothing here claims mutuality.
 */
internal fun SigilPresenceStore.seedDetectedSigil(proofId: UUID, peers: Int = 6, windows: Int = 8, tokenSeed: Int = 1) {
    val observations = createAggregationObservationInput()
    for (window in 0 until windows) {
        for (peer in 0 until peers) {
            if ((peer + window) % 3 == 0) continue
            val displayId = "d" + (tokenSeed * 100 + peer).toString(16).padStart(7, '0')
            check(addAggregationObservation(observations, 100L + window, "rpid-$peer-$window", displayId, false))
        }
    }
    val session = createSigilPresenceSession()
    val needed = sigilPresenceTokensNeeded(session, observations)
    for (offset in 0 until needed) {
        check(addSigilPresenceToken(session, observations, (tokenSeed * 1000 + offset + 1).toString(16).padStart(32, '0')))
    }
    persist(session, observations, proofId)
}

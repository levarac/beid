package org.levarac.beid.sensing

import java.util.UUID
import org.levarac.beid.persistence.SigilPresenceRecord
import org.levarac.beid.persistence.SigilPresenceStore
import org.levarac.beid.shared.sigil.SigilInput
import org.levarac.beid.shared.sigil.addSigilPresenceToken
import org.levarac.beid.shared.sigil.buildSigilPresenceInput
import org.levarac.beid.shared.sigil.createSigilPresenceSession
import org.levarac.beid.shared.sigil.sigilPresenceTokensNeeded

/**
 * One recording session's Sigil presence (beid#722): the shared, in-memory
 * display id -> token map, bound to [aggregation]'s observation input — the
 * SAME rows the counts come from, so the drawn peers are exactly the ones
 * behind `deviceCount` and the rings are exactly `windowCount`.
 *
 * A thin adapter in the sense of AGENTS.md's ownership table. Which
 * observations count, token assignment order, window ranks, caps and the byte
 * format are all `org.levarac.beid.shared.sigil` decisions; this class only
 * supplies CSPRNG tokens and calls through. It mirrors iOS
 * `SensingCoordinator.topUpSigilPresenceTokens`, `liveSigilInput` and
 * `persistSigilPresenceIfNeeded`.
 *
 * Never persisted, never logged. The owner drops it together with its
 * [AggregationRuntime] when the session resets, and a new session gets a new
 * one, so a second record of the same devices gets unrelated tokens.
 *
 * Main thread only, like the detection path that feeds [aggregation].
 */
internal class SigilPresenceRuntime(
    private val aggregation: AggregationRuntime,
    private val tokenSource: SigilPresenceTokenSource,
) {
    private val session = createSigilPresenceSession()

    /**
     * Supplies one token per display id shared says still needs one. Called
     * after every observation, so it costs one CSPRNG draw per new peer only.
     * A failed draw stops the loop and assigns nothing; the next observation
     * tries again, and a record left with an untokened peer is never written
     * (never a zero token).
     *
     * Reads nothing but the aggregation rows it shares with the counts, and
     * writes nothing but the in-memory session, so it adds no input to any
     * window, ledger entry, signature or submission.
     */
    fun topUpTokens() {
        val observations = aggregation.observations
        repeat(sigilPresenceTokensNeeded(session, observations)) {
            val token = tokenSource.nextToken() ?: return
            addSigilPresenceToken(session, observations, token)
        }
    }

    /** The session so far, built by the same shared builder that writes the row. `null` when shared cannot build one. */
    fun liveInput(): SigilInput? {
        val built = buildSigilPresenceInput(session, aggregation.observations)
        return if (built.isSuccess) built.input else null
    }

    /** Encodes this session through shared and stores it for [proofId]; see [SigilPresenceStore.persist]. */
    fun persist(store: SigilPresenceStore, proofId: UUID): SigilPresenceRecord =
        store.persist(session, aggregation.observations, proofId)
}

package org.levarac.parallax.venue

import org.levarac.parallax.registry.RegistryDefinitionRecord
import org.levarac.parallax.registry.RegistryEventContext
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Phase-1 current-lease readiness.
 *
 * The invariant under test: the local permit stops no later than the next ENIN;
 * the signed relay expiry is retained as verified signed-window metadata and is
 * never presented as the local permit deadline. The cap is the phase-1
 * re-verification cadence, not merely a shorter bound.
 *
 * ## If one of these goes red, read this first
 *
 * **A single red here does not name a single cause.** Measured 2026-09-10 by
 * deleting one guard at a time and recording what went red:
 *
 * - `theLeaseEninMustBeTheEninTheEnvelopeWasVerifiedAt` is the **only** witness
 *   for **two** guards — the cadence check (`verifiedAtEnin != currentEnin`) and
 *   the `noCurrentEnvelope` precedence. Deleting either turns exactly this test
 *   red and nothing else, so this test alone cannot tell you which one broke.
 * - `anEninAtOrAfterTheSignedRelayExpiryIsExpired` and
 *   `anExpiredEnvelopeIsNeverStretchedToFillAGap` are likewise the shared
 *   witnesses for both halves of the expiry mechanism: the per-candidate expiry
 *   detection and the `expired` precedence that reports it.
 * - `everyServingBlockCodeIsProducedByExactlyOneDecisionPath` went red for six
 *   of the twelve deleted guards. It is strong evidence that *something* broke
 *   and weak evidence about *what*.
 *
 * Neither member of either pair is redundant — they are the detect and report
 * halves of one mechanism. The limitation is in what a failure tells its reader,
 * not in the code.
 *
 * And the converse, because it is easy to assume otherwise:
 * `aLeaseInsideTheSignedWindowIsPermitted` went red for **none** of those twelve
 * deletions and could not have. Deleting a guard makes it *under*-fire; that
 * test detects a guard that *over*-fires. It is the witness for the opposite
 * failure class and its silence during deletion testing says nothing about it.
 */
class VenueCurrentLeaseTest {

    @Test
    fun currentLeaseStopsAtTheNextEninBoundaryNotTheSignedRelayExpiry() {
        val decision = evaluate()
        val lease = assertNotNull(decision.lease, "expected a lease, blocked with ${decision.blockCode}")
        // currentEnin 6000000, eninSeconds 300 -> (6000000 + 1) * 300.
        // The signed expiry is 6000002, so serving until it would give 1800000600.
        assertEquals(1_800_000_300L, lease.stopAtUnixSeconds)
        assertEquals(venueLeaseCurrentEnin(), lease.currentEnin)
    }

    @Test
    fun theSignedRelayExpiryIsCarriedSeparatelyFromTheLocalLeaseDeadline() {
        val lease = assertNotNull(evaluate().lease)
        assertEquals(6_000_002L, lease.signedRelayExpiresAtEnin)
        // Separately named, and strictly later here: the two must not collapse
        // into one field, because that is how a one-ENIN permit gets read as
        // verified signed-window coverage.
        assertTrue(lease.signedRelayExpiresAtEnin * 300L > lease.stopAtUnixSeconds)
    }

    @Test
    fun anEninBeforeTheSignedStartIsNotStartedWithARecheckInstant() {
        // notStarted is a property of the imported DEFINITION RECORD, not of an
        // envelope: before the event begins, native has nothing to verify and
        // never calls the SDK, so the candidate list is empty. The recheck
        // instant is the record's own validFrom, 1799997000 = ENIN 5999990.
        val decision = evaluateWith(emptyList(), clockSeconds = 5_999_989L * 300L)
        assertNull(decision.lease)
        assertEquals("notStarted", decision.blockCode)
        assertEquals(1_799_997_000L, decision.recheckAtUnixSeconds)
    }

    @Test
    fun anEninAtOrAfterTheSignedRelayExpiryIsExpired() {
        // The relay window is half-open: expiry 6000002 is the exclusive end,
        // so 6000002 itself is already expired, not the last servable ENIN.
        // The scheduling is one verified at 6000001, which is inside the window
        // and therefore reachable; the CLOCK has since moved past the expiry.
        // That is the real shape of expiry: the caller re-presents the current
        // lease's verification and shared tells it to verify afresh.
        for (enin in listOf(6_000_002L, 6_000_003L)) {
            val decision = evaluate(clockSeconds = enin * 300L, verifiedAtEnin = 6_000_001L)
            assertNull(decision.lease, "ENIN $enin must not serve")
            assertEquals("expired", decision.blockCode)
        }
    }

    @Test
    fun anExpiredEnvelopeIsNeverStretchedToFillAGap() {
        // An expired candidate beside a sibling the SDK rejected at this ENIN.
        // A later envelope in the bundle cannot appear as a verified candidate
        // at all -- verify refuses it because its validFromEnin is still ahead
        // -- so the honest mixed set is [expired, null]. The expired window must
        // not be stretched to cover now, and expired outranks envelopeRejected
        // so the answer is not decided by list order.
        val expired = venueLeaseScheduling(verifiedAtEnin = 6_000_001L)
        val decision = evaluateWith(listOf(expired, null), clockSeconds = 6_000_002L * 300L)
        assertNull(decision.lease)
        assertEquals("expired", decision.blockCode)
    }

    @Test
    fun anUnavailableClockBlocksWithoutInventingAnEnin() {
        val decision = evaluate(clockSeconds = null)
        assertNull(decision.lease)
        assertEquals("clockUnavailable", decision.blockCode)
        assertNull(decision.recheckAtUnixSeconds)
    }

    @Test
    fun noCandidateCoveringTheCurrentEninIsNoCurrentEnvelope() {
        // The definition is live -- the clock is inside the record's window --
        // but the bundle offered nothing for this instant. Distinct from
        // notStarted, which is the event not having begun, and from
        // envelopeRejected, which is envelopes offered and all refused.
        val decision = evaluateWith(emptyList())
        assertNull(decision.lease)
        assertEquals("noCurrentEnvelope", decision.blockCode)
    }

    @Test
    fun everyCandidateRejectedBySdkVerifyIsEnvelopeRejected() {
        // A null entry is an envelope Barnard verify rejected. All rejected is
        // distinct from none offered and from none currently in window.
        val decision = evaluateWith(listOf(null, null))
        assertNull(decision.lease)
        assertEquals("envelopeRejected", decision.blockCode)
    }

    @Test
    fun theLeaseEninMustBeTheEninTheEnvelopeWasVerifiedAt() {
        // The window covers the current ENIN, so a check that only tested the
        // window would issue a lease here. The verification is one ENIN stale,
        // which is precisely what the phase-1 cadence forbids: one verification
        // must not authorise service across a later boundary.
        // 5999999 is inside [5999990, 6000002) so this scheduling is one verify
        // really could have returned; only the clock has moved on by one ENIN.
        val stale = venueLeaseScheduling(verifiedAtEnin = venueLeaseCurrentEnin() - 1L)
        val decision = evaluateWith(listOf(stale))
        assertNull(decision.lease, "a verification from the previous ENIN must not serve this one")
        assertEquals("noCurrentEnvelope", decision.blockCode)
    }

    @Test
    fun aSupersededDefinitionRecordIsStaleDefinition() {
        // The imported record is still inside its own validity window; what
        // makes it stale is that a higher-sequence record now exists.
        val decision = staleDefinitionDecision()
        assertNull(decision.lease)
        assertEquals("staleDefinition", decision.blockCode)
    }

    @Test
    fun everyServingBlockCodeIsProducedByExactlyOneDecisionPath() {
        // Mechanical set equality against the frozen native enum's case names.
        // The enum declares no explicit raw values, so its raw values ARE these
        // names; shared emits them verbatim so no mapping stands between the
        // two, and a case added to the Swift enum makes this go red.
        val allNativeCases = setOf(
            "clockUnavailable", "notStarted", "expired", "noCurrentEnvelope",
            "envelopeRejected", "staleDefinition", "registryUnavailable",
        )
        // registryUnavailable is produced by the native adapter, which owns the
        // registry read; shared is never handed a failed read, because a failed
        // read yields no identity to evaluate in the first place.
        val nativeOnly = setOf("registryUnavailable")

        val produced = blockingScenarios().map { (name, decision) ->
            val code = assertNotNull(decision.blockCode, "scenario $name produced no block code")
            assertTrue(code in allNativeCases, "scenario $name produced $code, absent from the native enum")
            code
        }

        assertEquals(produced.size, produced.toSet().size, "two scenarios produced the same block code")
        assertEquals(allNativeCases - nativeOnly, produced.toSet())
        assertTrue((produced.toSet() intersect nativeOnly).isEmpty())
    }

    @Test
    fun aRecheckInstantIsCarriedOnlyWhenNotStarted() {
        for ((name, decision) in blockingScenarios()) {
            if (decision.blockCode == "notStarted") {
                assertNotNull(decision.recheckAtUnixSeconds, "$name must carry a recheck instant")
            } else {
                assertNull(decision.recheckAtUnixSeconds, "$name must not carry a recheck instant")
            }
        }
        // And the permitted case carries none either: a recheck instant is a
        // property of notStarted alone, not of "no lease" or of every decision.
        val permitted = evaluate()
        assertNotNull(permitted.lease)
        assertNull(permitted.recheckAtUnixSeconds)
    }

    @Test
    fun aClockPastTheDefinitionValidUntilIsExpiredBecauseTheEventEnded() {
        // The record's own validUntil is 1800003299; sit one second past it.
        // Deliberately with an EMPTY candidate list, so the only branch that can
        // produce expired is the record check. With candidates present the
        // per-envelope expiry guard could produce the same answer and this
        // would witness that guard instead of this one.
        val decision = evaluateWith(emptyList(), clockSeconds = 1_800_003_300L)
        assertNull(decision.lease)
        assertEquals("expired", decision.blockCode)
        assertNull(decision.recheckAtUnixSeconds)
    }

    @Test
    fun aLeaseInsideTheSignedWindowIsPermitted() {
        // The over-fire witness. If any guard above fires when it should not,
        // the canonical in-window case blocks and this goes red.
        val decision = evaluate()
        assertNull(decision.blockCode, "guard over-fired: blocked with ${decision.blockCode}")
        assertNull(decision.recheckAtUnixSeconds)
        val lease = assertNotNull(decision.lease)
        assertEquals(0, lease.selectedEnvelopeIndex)
        assertTrue(lease.stopAtUnixSeconds > venueLeaseClockSeconds())
    }

    /**
     * Every scheduling handed to these tests is one Barnard `verify` could
     * actually have returned: `validFromEnin <= verifiedAtEnin < relayExpiresAtEnin`.
     * Conditions are created by moving the CLOCK, never by fabricating a
     * post-verify state the real adapter can never produce — an assertion whose
     * subject is unreachable protects nothing.
     */
    private fun evaluate(
        clockSeconds: Long? = venueLeaseClockSeconds(),
        verifiedAtEnin: Long = venueLeaseCurrentEnin(),
    ): VenueCurrentLeaseDecision = evaluateWith(
        listOf(venueLeaseScheduling(verifiedAtEnin = verifiedAtEnin)), clockSeconds,
    )

    private fun evaluateWith(
        candidates: List<VenueVerifiedScheduling?>,
        clockSeconds: Long? = venueLeaseClockSeconds(),
    ): VenueCurrentLeaseDecision =
        evaluateVenueCurrentLease(venueLeaseIdentity(), candidates, clockSeconds)

    /** One scenario per shared-produced block code, named so a failure says which. */
    private fun blockingScenarios(): List<Pair<String, VenueCurrentLeaseDecision>> = listOf(
        "clockUnavailable" to evaluate(clockSeconds = null),
        "notStarted" to evaluateWith(emptyList(), clockSeconds = 5_999_989L * 300L),
        "expired" to evaluate(clockSeconds = 6_000_002L * 300L, verifiedAtEnin = 6_000_001L),
        "noCurrentEnvelope" to evaluateWith(emptyList()),
        "envelopeRejected" to evaluateWith(listOf(null)),
        "staleDefinition" to staleDefinitionDecision(),
    )

    private fun staleDefinitionDecision(): VenueCurrentLeaseDecision {
        val vector = venueLeaseVector()
        val imported = vector.venueDefinitionRecord()
        val successor = RegistryDefinitionRecord(
            sequence = imported.sequence + 1,
            previousDefinitionDigestHex = imported.definitionDigestHex,
            definitionDigestHex = imported.previousDefinitionDigestHex,
            validFrom = imported.validUntil + 1,
            validUntil = imported.validUntil + 6_000,
            anchoredAt = imported.anchoredAt + 1,
        )
        val context = RegistryEventContext(
            schemaVersion = 1, registration = vector.venueRegistration(), definitionState = 1,
            latestSequence = successor.sequence, definitions = listOf(imported, successor),
        )
        return evaluateVenueCurrentLease(
            venueLeaseIdentity(context = context), listOf(venueLeaseScheduling()), venueLeaseClockSeconds(),
        )
    }
}

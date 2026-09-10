package org.levarac.parallax.venue

/**
 * Scheduling facts taken from one SDK-verified B005 envelope.
 *
 * Shared never parses B005 and never checks a signature: Barnard owns those and
 * rechecking them here would be a second implementation of its protocol
 * semantics (KMP-002). The native adapter calls Barnard `verify` and hands the
 * verified result's fields in through this carrier, which is why its
 * constructor is public while the decision outputs below are opaque.
 *
 * [verifiedAtEnin] is the ENIN the SDK was asked to verify at. It is carried
 * separately from the device clock on purpose: a lease may only be issued for
 * the ENIN its envelope was actually verified at, and reusing an older
 * verification across an ENIN boundary is the phase-2 behaviour the phase-1
 * cadence rule exists to prevent.
 */
public class VenueVerifiedScheduling public constructor(
    public val validFromEnin: Long,
    public val validThroughEnin: Long,
    public val relayExpiresAtEnin: Long,
    public val eninSeconds: Int,
    public val verifiedAtEnin: Long,
)

/**
 * Permission to serve one envelope for exactly one ENIN.
 *
 * [stopAtUnixSeconds] is the **local permit deadline**: the exclusive instant at
 * the `currentEnin + 1` boundary. [signedRelayExpiresAtEnin] is the verified
 * signed-window metadata carried alongside for diagnostics and phase-2
 * readiness. They are separate fields because they answer different questions,
 * and the signed expiry must never be presented as the local permit deadline.
 *
 * The cap is not merely a shorter bound. It is the phase-1 re-verification
 * cadence: stopping at the next ENIN forces a fresh SDK verification every
 * ENIN, whereas serving until the signed expiry would let a single verification
 * authorise service across up to eleven later ENIN boundaries, which is
 * schedule handling and belongs to phase 2. The pinned SDK permits using the
 * signed expiry as a bound; it does not require serving until it, and it says
 * nothing that waives fresh verification.
 */
public class VenueCurrentLease internal constructor(
    public val selectedEnvelopeIndex: Int,
    public val currentEnin: Long,
    public val stopAtUnixSeconds: Long,
    public val signedRelayExpiresAtEnin: Long,
)

/**
 * Exactly one of [lease] and [blockCode] is non-null.
 *
 * [blockCode] uses the `VenueServingBlock` case names verbatim so the native
 * consumer's exhaustive switch and this decision share one vocabulary with no
 * translation step between them. That deliberately differs from the snake_case
 * codes in [VenueBundleIdentityCheck] next door; the two are not unified here
 * because doing so would change published identity behaviour inside a change
 * that is meant to add serving readiness.
 *
 * [recheckAtUnixSeconds] is non-null if and only if [blockCode] is
 * `notStarted`, mirroring the failable initialiser of the native
 * `VenueServingRejection`.
 */
public class VenueCurrentLeaseDecision internal constructor(
    public val lease: VenueCurrentLease?,
    public val blockCode: String?,
    public val recheckAtUnixSeconds: Long?,
)

/**
 * Decide whether any verified candidate may be served right now, and for how long.
 *
 * [candidates] is **positional**: one entry per envelope the caller offered, in
 * bundle order, so `candidates.size` is either `identity.bundle.envelopeCount`
 * or zero when the caller had nothing to verify. A null entry is an envelope
 * Barnard `verify` refused **at this ENIN**. Shared does not learn *why* it was
 * refused and must not try to: that is Barnard's judgement (KMP-002). A future
 * envelope therefore arrives as a rejection rather than as "not yet", which is
 * correct rather than a loss of information — "not yet" is answered from the
 * definition record, not from an envelope.
 *
 * A null [clockUnixSeconds] is an unavailable clock reading, which is a block
 * rather than a reason to invent an ENIN.
 *
 * **How `expired` is reachable at all**, since a genuinely expired envelope
 * would simply fail `verify` and arrive as null: the caller re-presents the
 * scheduling of the lease it currently holds, verified at an earlier ENIN, and
 * the clock has since crossed `relayExpiresAtEnin`. `expired` is shared telling
 * the caller to verify afresh. **That is the re-verification cadence appearing
 * in the API rather than only in the prose** — it and the stale-verification
 * case in the check order are one mechanism at two distances, and `expired`
 * wins because the closed signed window is the more specific fact.
 *
 * **Check order.** Written down before the implementation so that this is a
 * design rather than whatever shape first turned the tests green — an
 * implementation satisfying the same tests in a different order encodes a
 * different policy while staying green:
 *
 * 1. clock unavailable -> `clockUnavailable`
 * 2. the imported definition record is superseded -> `staleDefinition`
 * 3. the current instant is before that record's `validFrom` -> `notStarted`,
 *    with the recheck instant at `validFrom`
 * 4. per candidate, in bundle order: rejected by the SDK, expired, or covering
 *    now with a coherent verification -> the first coherent candidate wins
 * 5. otherwise the precedence below
 *
 * **`notStarted` is a property of the definition record, not of any envelope.**
 * This is what separates it from `noCurrentEnvelope`, and without it the two
 * are indistinguishable: both are "the current ENIN precedes this candidate's
 * `validFromEnin`" and would need contradictory codes for the same input class.
 * The event has not begun -> `notStarted`; the event is live but nothing signed
 * covers this moment -> `noCurrentEnvelope`.
 *
 * **Precedence when no candidate is servable**, so a mixed set is not decided
 * by list order: `expired` outranks `noCurrentEnvelope`, which outranks
 * `envelopeRejected`. A set holding an expired envelope and a rejected sibling
 * reports `expired`, because the nearer and more actionable fact is that
 * something was serving and stopped.
 *
 * **Three inputs, not two**, which the precedence above cannot settle because
 * they are different inputs rather than competing outcomes:
 *
 * - empty [candidates] — the caller offered nothing for this instant ->
 *   `noCurrentEnvelope`
 * - offered and **verified**, but none usable now (out of window, or verified
 *   at another ENIN) -> also `noCurrentEnvelope`
 * - offered and **every one refused** by the SDK -> `envelopeRejected`
 *
 * The middle case is why `noCurrentEnvelope` covers two inputs rather than
 * one. Folding it into `envelopeRejected` would report a stale verification as
 * though Barnard had rejected the bytes, which is a different and misleading
 * fact: the SDK accepted them, and it is the passage of an ENIN boundary that
 * made them unusable.
 *
 * **The clock past the definition record's `validUntil`** — the event is over
 * rather than superseded — is placed at `expired`, and it is written here
 * because nothing else places it and an unplaced case gets decided by whichever
 * branch happens to catch it. `staleDefinition` stays reserved for its own
 * meaning: a higher-sequence record supersedes the imported one. The two are
 * different facts and an event that simply ended is not a stale import.
 */
public fun evaluateVenueCurrentLease(
    identity: VenueBundleIdentity,
    candidates: List<VenueVerifiedScheduling?>,
    clockUnixSeconds: Long?,
): VenueCurrentLeaseDecision {
    // 1. No clock reading is a block, never a reason to invent an ENIN.
    val clock = clockUnixSeconds ?: return blockedBy("clockUnavailable")

    // 2. The imported record must still be the current one.
    val record = identity.registryContext.definitions.firstOrNull {
        it.sequence == identity.bundle.definitionSequence
    } ?: return blockedBy("staleDefinition")
    if (identity.registryContext.latestSequence > record.sequence) {
        return blockedBy("staleDefinition")
    }

    // 3. Decided from the RECORD, not from any envelope. Before the event
    //    begins the caller has nothing to verify, so this is reached with an
    //    empty candidate list and must not depend on one being present.
    if (clock < record.validFrom) {
        return VenueCurrentLeaseDecision(null, "notStarted", record.validFrom)
    }
    if (clock > record.validUntil) return blockedBy("expired")

    // 4. First coherent candidate in bundle order wins.
    var sawExpired = false
    var sawVerifiedCandidate = false
    candidates.forEachIndexed { index, scheduling ->
        if (scheduling == null) return@forEachIndexed
        sawVerifiedCandidate = true
        val eninSeconds = scheduling.eninSeconds.toLong()
        // Defensive, kept deliberately, and NOT redundant the way the guard
        // below is. `eninSeconds` comes from a UInt16 the SDK fills, so no real
        // verified envelope reaches this with a non-positive value and no test
        // covers the branch — deleting it turns nothing red, measured.
        //
        // Delete it anyway and the very next line divides by it: an immediate
        // ArithmeticException on a path nothing guards. So a surviving mutant
        // here is expected and is not evidence the line is dead weight. The
        // distinction worth keeping: the guard below duplicates a check someone
        // else already performs, while this one is the only thing standing
        // between a zero and a division.
        if (eninSeconds <= 0L) return@forEachIndexed
        val currentEnin = floorDivLong(clock, eninSeconds)

        // The relay window is half-open, so the expiry ENIN is already outside it.
        if (currentEnin >= scheduling.relayExpiresAtEnin) {
            sawExpired = true
            return@forEachIndexed
        }
        // Redundant against a Barnard invariant, and kept deliberately.
        // `verify` guarantees validFromEnin <= verifiedAtEnin < relayExpiresAtEnin,
        // so any candidate whose verifiedAtEnin equals the current ENIN already
        // satisfies this, and this line can never be the SOLE decider: it only
        // fires where the cadence check below would fire too. Measured — deleting
        // it turns no test red, so no test can witness it either.
        //
        // It stays because the invariant is a cross-repo guarantee consumed at a
        // pinned SDK version, not something this file enforces. A Barnard that
        // weakened it would turn a removed line into a silent hole, and the
        // witness set cannot protect code that is no longer there.
        if (currentEnin < scheduling.validFromEnin) return@forEachIndexed
        // The cadence rule: a verification authorises only the ENIN it ran at.
        if (scheduling.verifiedAtEnin != currentEnin) return@forEachIndexed

        return VenueCurrentLeaseDecision(
            lease = VenueCurrentLease(
                selectedEnvelopeIndex = index,
                currentEnin = currentEnin,
                // The conservative cap, never the signed expiry.
                stopAtUnixSeconds = (currentEnin + 1L) * eninSeconds,
                signedRelayExpiresAtEnin = scheduling.relayExpiresAtEnin,
            ),
            blockCode = null,
            recheckAtUnixSeconds = null,
        )
    }

    // 5. Precedence, so a mixed set is not decided by list order.
    if (sawExpired) return blockedBy("expired")
    if (sawVerifiedCandidate) return blockedBy("noCurrentEnvelope")
    if (candidates.isNotEmpty()) return blockedBy("envelopeRejected")
    return blockedBy("noCurrentEnvelope")
}

private fun blockedBy(code: String): VenueCurrentLeaseDecision =
    VenueCurrentLeaseDecision(null, code, null)

/** Kotlin common has no `floorDiv`, and a clock value is not guaranteed positive. */
private fun floorDivLong(a: Long, b: Long): Long {
    var quotient = a / b
    if (a % b != 0L && ((a xor b) < 0L)) quotient--
    return quotient
}

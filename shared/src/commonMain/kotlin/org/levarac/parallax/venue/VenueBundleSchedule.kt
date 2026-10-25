package org.levarac.parallax.venue

/** A half-open interval, with its own ENIN unit. No signature or serving authority. */
public class VenueScheduleInterval public constructor(
    public val start: Long,
    public val end: Long,
    public val eninSeconds: Long,
)

/** The complete-ENIN bounds used by the existing iOS import coverage oracle. */
public class VenueDefinitionEninWindow internal constructor(public val start: Long, public val end: Long)

/** Import evidence only. A current, freshly verified lease is still required before serving. */
public class VenueVerifiedSchedule internal constructor(
    public val envelopeCount: Int,
    public val eninSeconds: Int,
    public val requiredStartEnin: Long,
    public val requiredEndEnin: Long,
)

/** Exactly one of schedule/failureCode is present; codes describe import failures, never readiness. */
public class VenueScheduleCheck internal constructor(
    public val schedule: VenueVerifiedSchedule?,
    public val failureCode: String?,
)

/**
 * Verify the complete import schedule, without reading a clock or doing I/O.
 *
 * Native Barnard must verify EVERY decoded envelope at its own start ENIN and
 * check registry agreement first. Pass its verified scheduling in bundle order;
 * a null entry represents any malformed, signature-rejected or disagreeing
 * envelope. Shared never decodes B005, verifies signatures, or reimplements its
 * signing/cadence-limit semantics (KMP-002).
 *
 * Oracle: iOS ProductionVenueBundleVerifier at 59862267. All envelopes must have
 * one cadence, non-overlapping [validFromEnin, relayExpiresAtEnin) eligibility,
 * and tile the definition's required [ceil(validFrom / cadence), lastCompleteEnin)
 * span. The last complete definition ENIN is deliberately EXCLUSIVE for coverage:
 * the SDK's signed relay expiry cannot extend past that ENIN. validThroughEnin
 * is metadata, not an inclusive relay endpoint. Input verification must itself
 * have happened within the half-open eligibility interval.
 *
 * Rejections: malformed_envelope, outside_definition_window, mixed_cadence,
 * overlap (including duplicates), gap, invalid_definition_window.
 * A successful schedule authorizes no broadcasting and contains no clock lease.
 */
public fun verifyVenueBundleSchedule(
    envelopes: List<VenueVerifiedScheduling?>,
    validFromUnixSeconds: Long,
    validUntilUnixSeconds: Long,
): VenueScheduleCheck {
    if (envelopes.isEmpty()) return scheduleRejected("malformed_envelope")
    var referenceCadence: Int? = null
    val intervals = ArrayList<VenueScheduleInterval>(envelopes.size)
    for (candidate in envelopes) {
        val envelope = candidate ?: return scheduleRejected("malformed_envelope")
        val interval = VenueScheduleInterval(envelope.validFromEnin, envelope.relayExpiresAtEnin, envelope.eninSeconds.toLong())
        if (normalizedInterval(interval) == null ||
            envelope.verifiedAtEnin < interval.start || envelope.verifiedAtEnin >= interval.end
        ) return scheduleRejected("malformed_envelope")
        val window = venueDefinitionEninWindow(validFromUnixSeconds, validUntilUnixSeconds, interval.eninSeconds)
            ?: return scheduleRejected("invalid_definition_window")
        if (interval.start < window.start || interval.end > window.end || envelope.validThroughEnin > window.end) {
            return scheduleRejected("outside_definition_window")
        }
        if (referenceCadence != null && referenceCadence != envelope.eninSeconds) return scheduleRejected("mixed_cadence")
        referenceCadence = envelope.eninSeconds
        intervals += interval
    }
    if (venueScheduleHasOverlap(intervals)) return scheduleRejected("overlap")
    val cadence = requireNotNull(referenceCadence)
    val window = requireNotNull(venueDefinitionEninWindow(validFromUnixSeconds, validUntilUnixSeconds, cadence.toLong()))
    if (venueScheduleHasGap(intervals, window.start, window.end)) return scheduleRejected("gap")
    return VenueScheduleCheck(VenueVerifiedSchedule(envelopes.size, cadence, window.start, window.end), null)
}

private fun scheduleRejected(code: String): VenueScheduleCheck = VenueScheduleCheck(null, code)

/** Shared arithmetic also used by the native current-lease adapter; divisor must be nonzero. */
public fun venueFloorDiv(a: Long, b: Long): Long {
    val q = a / b
    val r = a % b
    return if (r != 0L && (r < 0L) != (b < 0L)) q - 1 else q
}

public fun venueFloorMod(a: Long, b: Long): Long {
    val r = a % b
    return if (r != 0L && (r < 0L) != (b < 0L)) r + b else r
}

/** Start rounded up; last complete ENIN rounded down, matching the iOS oracle. */
public fun venueDefinitionEninWindow(
    validFromUnixSeconds: Long,
    validUntilUnixSeconds: Long,
    eninSeconds: Long,
): VenueDefinitionEninWindow? {
    if (eninSeconds <= 0 || validFromUnixSeconds < 0 || validUntilUnixSeconds < validFromUnixSeconds) return null
    val start = validFromUnixSeconds / eninSeconds + if (validFromUnixSeconds % eninSeconds == 0L) 0 else 1
    val q = validUntilUnixSeconds / eninSeconds
    val end = if (validUntilUnixSeconds % eninSeconds == eninSeconds - 1) q else q - 1
    return VenueDefinitionEninWindow(start, end)
}

/** Compare wall-clock ranges, not raw ENIN indices from possibly different cadences. */
public fun venueScheduleHasOverlap(intervals: List<VenueScheduleInterval>): Boolean {
    val normalized = ArrayList<VenueScheduleInterval>(intervals.size)
    for (interval in intervals) {
        val current = normalizedInterval(interval) ?: return true
        if (normalized.any { current.start < it.end && it.start < current.end }) return true
        normalized += current
    }
    return false
}

private fun normalizedInterval(interval: VenueScheduleInterval): VenueScheduleInterval? {
    val cadence = interval.eninSeconds
    if (cadence <= 0 || interval.start >= interval.end) return null
    if (interval.start < Long.MIN_VALUE / cadence || interval.start > Long.MAX_VALUE / cadence ||
        interval.end < Long.MIN_VALUE / cadence || interval.end > Long.MAX_VALUE / cadence
    ) return null
    return VenueScheduleInterval(interval.start * cadence, interval.end * cadence, 1)
}

/** Coverage alone tolerates overlaps; the complete verifier separately rejects them. */
public fun venueScheduleHasGap(
    candidates: List<VenueScheduleInterval>,
    requiredStart: Long,
    requiredEnd: Long,
): Boolean {
    if (requiredStart >= requiredEnd) return false
    var coveredThrough = requiredStart
    for (candidate in candidates.filter { it.start < it.end }.sortedBy { it.start }) {
        if (candidate.start > coveredThrough) break
        coveredThrough = maxOf(coveredThrough, candidate.end)
        if (coveredThrough >= requiredEnd) return false
    }
    return coveredThrough < requiredEnd
}

/** Compatibility surface for existing iOS helper tests; all coverage rules live here. */
public fun venueScheduleCoverageCode(
    referenceEninSeconds: Long?,
    validFromUnixSeconds: Long,
    validUntilUnixSeconds: Long,
    coverageIntervals: List<VenueScheduleInterval>,
): String {
    val cadence = referenceEninSeconds ?: return "uncomputable"
    val window = venueDefinitionEninWindow(validFromUnixSeconds, validUntilUnixSeconds, cadence) ?: return "uncomputable"
    return if (venueScheduleHasGap(coverageIntervals, window.start, window.end)) "gap" else "covered"
}

package org.levarac.beid.shared.aggregation

/**
 * One native record tagged with its position in the native list it came
 * from. Shared never interprets [recordIndex]; it is round-tripped unchanged
 * so a caller can map [DayRollupResult]'s matches back to its own records.
 */
internal class DayRollupRecord(
    val recordIndex: Int,
    val epochMillis: Long,
)

/**
 * Opaque accumulator of native records to bucket against a [DayRollupWindow].
 *
 * Mirrors [AggregationObservationInput]'s shape (create, add one at a time,
 * read back): a flat, final, concrete exported boundary, not a raw
 * `List<...>` parameter.
 */
public class DayRollupInput internal constructor(
    internal val records: MutableList<DayRollupRecord> = mutableListOf(),
)

public fun createDayRollupInput(): DayRollupInput = DayRollupInput()

/**
 * Adds one native record: [epochMillis] is that record's own timestamp (UTC
 * epoch milliseconds — shared has no timezone concept of its own, see
 * [DayRollupWindow]); [recordIndex] is an opaque position native assigns
 * (typically the record's index into the native array `epochMillis` was read
 * from) so [rollupRecordsForDay] can report exactly *which* records matched,
 * not only how many.
 */
public fun addDayRollupRecord(
    input: DayRollupInput,
    recordIndex: Int,
    epochMillis: Long,
) {
    input.records += DayRollupRecord(recordIndex = recordIndex, epochMillis = epochMillis)
}

/**
 * A day's boundary as two already-resolved UTC epoch-millisecond instants.
 *
 * **Day-boundary invariant (gh#291, fixed here as the decision this family
 * implements):** a record belongs to this window iff its timestamp `t`
 * satisfies `startEpochMillisInclusive <= t < endEpochMillisExclusive` — a
 * half-open interval, inclusive of the start, exclusive of the end. This is
 * the same shape as a half-open range anywhere else in this codebase: it is
 * the only shape under which two adjacent, non-overlapping windows (today
 * and tomorrow, both built the same way) partition every possible instant
 * with no gap and no double coverage. An inclusive-both-ends or
 * exclusive-both-ends rule would either double-count or silently drop the
 * exact instant at midnight, which is precisely the risky edge case this
 * family exists to get right.
 *
 * **Ownership boundary (AGENTS.md): shared does not decide what "today" is.**
 * "Which calendar day does this instant belong to, in which timezone, with
 * which calendar" is OS/locale integration — native's job, not a portable,
 * deterministic one. Two devices in different timezones must legitimately
 * disagree about which day a given instant falls on. So this type carries
 * two already-resolved instants handed in by a native caller, never a
 * timezone, calendar, or "now": native decides the boundary and hands it to
 * shared as data; shared does pure, deterministic counting given that input.
 *
 * Native must resolve `endEpochMillisExclusive` with a calendar-aware
 * "add one day" (e.g. `Calendar.date(byAdding: .day, value: 1, to:)`), never
 * `startEpochMillisInclusive + 86_400_000`: a fixed-milliseconds day breaks on
 * a DST transition, where the local calendar day is 23 or 25 hours long.
 * Shared cannot detect that mistake from inside this function — the input
 * would still be a valid, non-empty window — so getting it right is entirely
 * on the native adapter that builds one.
 */
public class DayRollupWindow internal constructor(
    internal val startEpochMillisInclusive: Long,
    internal val endEpochMillisExclusive: Long,
)

/**
 * Builds a [DayRollupWindow]. Returns null when the window is empty or
 * inverted (`endEpochMillisExclusive <= startEpochMillisInclusive`) — shared
 * checks only this boundary shape; deciding which two instants bound "today"
 * is native's job (see [DayRollupWindow]'s doc comment).
 */
public fun dayRollupWindow(
    startEpochMillisInclusive: Long,
    endEpochMillisExclusive: Long,
): DayRollupWindow? {
    if (endEpochMillisExclusive <= startEpochMillisInclusive) return null
    return DayRollupWindow(
        startEpochMillisInclusive = startEpochMillisInclusive,
        endEpochMillisExclusive = endEpochMillisExclusive,
    )
}

/**
 * One matching record, carrying back the `recordIndex` its native caller
 * originally tagged it with. A nullable *class* return (see
 * [DayRollupResult.matchAt]), not a nullable primitive `Int` — mirrors
 * [WindowAggregates.windowAt]'s proven indexed-accessor shape rather than
 * introducing a new, unproven nullable-primitive export shape.
 */
public class DayRollupMatch internal constructor(
    public val recordIndex: Int,
)

/**
 * Result of bucketing a [DayRollupInput]'s records against one
 * [DayRollupWindow]. Matches are ascending by `recordIndex`, each reported
 * exactly once; [recordCount] is defined as the match count, never
 * independently recomputed, so the two can never disagree with each other.
 */
public class DayRollupResult internal constructor(
    internal val matches: List<DayRollupMatch>,
) {
    public val recordCount: Int
        get() = matches.size

    public fun matchAt(position: Int): DayRollupMatch? = matches.getOrNull(position)
}

/**
 * Counts (and reports) which of [input]'s records fall inside [window]'s
 * half-open interval. See [DayRollupWindow] for the boundary invariant this
 * implements and for why the window is opaque input rather than something
 * this function derives itself.
 */
public fun rollupRecordsForDay(
    input: DayRollupInput,
    window: DayRollupWindow,
): DayRollupResult {
    val matches = input.records
        .asSequence()
        .filter {
            it.epochMillis >= window.startEpochMillisInclusive &&
                it.epochMillis < window.endEpochMillisExclusive
        }
        .sortedBy { it.recordIndex }
        .map { DayRollupMatch(recordIndex = it.recordIndex) }
        .toList()
    return DayRollupResult(matches = matches)
}

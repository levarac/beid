package org.levarac.beid.shared.event

/**
 * The parameters that decide when a crowd majority counts as clear.
 *
 * All three are integers. A floating-point ratio would put rounding into a
 * decision that iOS and Android must answer identically, so the lead test is
 * expressed as a percentage and evaluated by multiplication — no division, and
 * no divide-by-zero case when the runner-up has no relays.
 *
 * ## Proposed defaults — PRODUCT SIGN-OFF REQUIRED
 *
 * [defaultRelayMajorityParameters] proposes `recentWindowCount = 3`,
 * `minimumLeadingRelayCount = 3`, `minimumLeadPercent = 200`. These values are a
 * starting proposal from the implementation side. They decide when the app skips
 * asking the user and starts recording on its own, which is a product judgement
 * and is **not settled by this code**. The reasoning behind each, so it can be
 * argued with rather than guessed at:
 *
 * - `recentWindowCount = 3` — at the default 300-second ENIN window that is
 *   about fifteen minutes of evidence. Long enough that one quiet window does
 *   not flip the answer, short enough that the app reacts when a room's crowd
 *   actually changes. It is a count of windows, never a duration, because the
 *   window length is itself a runtime parameter.
 * - `minimumLeadingRelayCount = 3` — below this there is no crowd to be a
 *   majority of. Without a floor, one device relaying one event beats an empty
 *   field and the app would auto-start on a single stranger's phone, which is
 *   exactly the prank beid#139 exists to blunt.
 * - `minimumLeadPercent = 200` — the leader needs at least twice the runner-up.
 *   A ratio rather than an absolute margin so the same number works at a
 *   ten-person meetup and a three-thousand-person conference; an absolute margin
 *   of two is meaningless at the second scale and impossible at the first.
 *
 * Raising any of the three makes the app ask more often and auto-start less;
 * lowering them does the reverse. Nothing here has been validated against a real
 * venue, because the input this predicate consumes cannot be measured yet.
 */
public class RelayMajorityParameters internal constructor(
    public val recentWindowCount: Int,
    public val minimumLeadingRelayCount: Int,
    public val minimumLeadPercent: Int,
)

/**
 * Swift-exportable builder for per-event, per-window relay counts.
 *
 * **Nothing can fill this from live sensing today.** Barnard 0.3.0's B005
 * receive API carries no relayer identity, so a relay count cannot be derived
 * from it (levarac/barnard#128). This input exists so the decision, its
 * parameters and its vectors are fixed and reviewable now, and so the supply can
 * be connected without renegotiating the interface. Do not feed it a count
 * synthesized from peripheral identity observed in beid's own scan layer; see
 * [RelayCount].
 */
public class RelayObservationInput internal constructor(
    internal val counts: MutableMap<String, MutableMap<Long, Int>> = mutableMapOf(),
) {
    public val eventCount: Int
        get() = counts.size
}

/**
 * The one decision beid#141's screen consumes: is a majority clear, and which
 * event is it?
 *
 * The screen holds no threshold of its own — it receives this verdict and draws
 * it — so the parameters above can change without touching either app.
 *
 * `leadingRelayCount` and `runnerUpRelayCount` are reported so a caller can show
 * its reasoning, not so it can re-derive the verdict. A zero here means zero
 * relays were counted in the evaluated windows, which is an observation about
 * the supplied input. It does not mean the same thing as [RelayCount] being
 * absent, which means no count can be obtained at all.
 */
public class RelayMajorityVerdict internal constructor(
    public val isSuccess: Boolean,
    public val errorCode: String?,
    public val isMajorityClear: Boolean,
    public val leadingEventCodeHashHex: String?,
    public val leadingRelayCount: Int,
    public val runnerUpRelayCount: Int,
)

/** Builds parameters, or null when a value would make the decision meaningless. */
public fun createRelayMajorityParameters(
    recentWindowCount: Int,
    minimumLeadingRelayCount: Int,
    minimumLeadPercent: Int,
): RelayMajorityParameters? {
    if (recentWindowCount < 1 || minimumLeadingRelayCount < 1 || minimumLeadPercent < 100) {
        return null
    }
    return RelayMajorityParameters(
        recentWindowCount = recentWindowCount,
        minimumLeadingRelayCount = minimumLeadingRelayCount,
        minimumLeadPercent = minimumLeadPercent,
    )
}

/** The proposal described on [RelayMajorityParameters]. Not yet signed off. */
public fun defaultRelayMajorityParameters(): RelayMajorityParameters =
    RelayMajorityParameters(
        recentWindowCount = 3,
        minimumLeadingRelayCount = 3,
        minimumLeadPercent = 200,
    )

public fun createRelayObservationInput(): RelayObservationInput = RelayObservationInput()

/**
 * Records that [relayCount] devices were seen relaying [eventCodeHashHex] in
 * [windowIndex]. Returns false on a malformed hash, a negative window, or a
 * negative count.
 *
 * Two entries for the same event and window resolve to the **larger** count.
 * Last-one-wins would make the verdict depend on the order the caller happened
 * to add rows in, and the two platforms would then disagree over identical
 * evidence.
 */
public fun addRelayObservation(
    input: RelayObservationInput,
    eventCodeHashHex: String,
    windowIndex: Long,
    relayCount: Int,
): Boolean {
    if (windowIndex < 0L || relayCount < 0) {
        return false
    }
    val key = eventCodeHashHex.normalizedEventCodeHashHexOrNull() ?: return false

    val perWindow = input.counts.getOrPut(key) { mutableMapOf() }
    val existing = perWindow[windowIndex]
    if (existing == null || relayCount > existing) {
        perWindow[windowIndex] = relayCount
    }
    return true
}

/**
 * Evaluates the crowd-majority decision over the windows ending at
 * [atWindowIndex].
 *
 * The evaluated range is the [RelayMajorityParameters.recentWindowCount] windows
 * ending at [atWindowIndex] inclusive. Windows after [atWindowIndex] are excluded
 * so the verdict is reproducible: asking about a past window must give the same
 * answer it gave at the time.
 *
 * Each event's score across that range is the **maximum** of its per-window
 * counts, never the sum. A device heard in three windows is one device, but it
 * appears in three windows' counts, so summing inflates with dwell time and
 * hands the lead to whichever event has been lingering longest rather than to
 * the one with the bigger crowd. This is the same trap the aggregation family
 * already documents for its per-window peer count, and it is settled the same
 * way here rather than answered a second, different way.
 *
 * A majority is clear when the leader meets the floor, is **strictly ahead** of
 * the runner-up, and beats it by at least the lead percentage.
 *
 * The strictly-ahead test is not redundant with the lead percentage, and an
 * earlier version of this code wrongly claimed it was. At the lowest admitted
 * `minimumLeadPercent` of 100 the lead test reduces to
 * `leading * 100 >= runnerUp * 100`, which every tie satisfies — so a dead tie
 * above the relay floor was reported as a clear majority, with the winner
 * decided by the hash-ascending sort that exists only to make ordering
 * deterministic. An arbitrary tiebreak was deciding whether the app starts
 * recording without asking the user.
 *
 * A tie is the definition of a majority that is not clear, so it is rejected
 * here explicitly rather than left to a parameter value to prevent. Relying on a
 * parameter to uphold an invariant means the invariant holds only for the
 * parameters someone happened to test.
 *
 * A negative [atWindowIndex] fails the call whole rather than returning "not
 * clear", because "we cannot evaluate this" and "the crowd is ambiguous" lead a
 * caller to do different things.
 */
public fun evaluateRelayMajority(
    input: RelayObservationInput,
    parameters: RelayMajorityParameters,
    atWindowIndex: Long,
): RelayMajorityVerdict {
    if (atWindowIndex < 0L) {
        return RelayMajorityVerdict(
            isSuccess = false,
            errorCode = "invalid_window_index",
            isMajorityClear = false,
            leadingEventCodeHashHex = null,
            leadingRelayCount = 0,
            runnerUpRelayCount = 0,
        )
    }

    val oldestIncludedWindow = atWindowIndex - parameters.recentWindowCount + 1
    val scored = input.counts.entries
        .map { (key, perWindow) ->
            key to perWindow.entries
                .filter { it.key in oldestIncludedWindow..atWindowIndex }
                .maxOfOrNull { it.value }
                .orZero()
        }
        // Descending score, then hash ascending, so an equal-score pair is
        // ordered the same way on both platforms even though neither wins.
        .sortedWith(compareByDescending<Pair<String, Int>> { it.second }.thenBy { it.first })

    val leading = scored.firstOrNull()
    val leadingCount = leading?.second ?: 0
    val runnerUpCount = scored.getOrNull(1)?.second ?: 0

    val meetsFloor = leadingCount >= parameters.minimumLeadingRelayCount
    val isStrictlyAhead = leadingCount > runnerUpCount
    // Long arithmetic: both sides are a product of two Ints, which overflows Int
    // for large counts and would silently invert the comparison.
    val meetsLead =
        leadingCount.toLong() * 100L >= runnerUpCount.toLong() * parameters.minimumLeadPercent.toLong()

    return RelayMajorityVerdict(
        isSuccess = true,
        errorCode = null,
        isMajorityClear = meetsFloor && isStrictlyAhead && meetsLead,
        leadingEventCodeHashHex = leading?.first,
        leadingRelayCount = leadingCount,
        runnerUpRelayCount = runnerUpCount,
    )
}

private fun Int?.orZero(): Int = this ?: 0

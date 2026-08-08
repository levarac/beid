package org.levarac.beid.shared.event

/**
 * Mirrors the retention cap Barnard's own `BarnardEventInfoDiscoverySession`
 * applies (32 distinct event code hashes). Retaining more than the SDK can
 * deliver would only ever hold events this store can no longer be told about.
 */
internal const val MAX_RETAINED_EVENT_COUNT = 32

/** A B005 event code hash is the 8-byte B004 hash, so 16 hex characters. */
internal const val EVENT_CODE_HASH_HEX_LENGTH = 16

/**
 * The display name a B005 hint carries is bounded at 64 UTF-8 bytes by the
 * Barnard codec. This store never renders that name (see [recordEventInfoHint])
 * but a definition's name is bounded by the same product rule.
 */
internal const val MAX_EVENT_DISPLAY_NAME_BYTES = 64

internal class EventObservationRecord(
    val eventCodeHashHex: String,
    var firstSeenWindowIndex: Long,
    var lastSeenWindowIndex: Long,
    var observationCount: Int,
)

/**
 * Observer-local retention of which events have been heard nearby.
 *
 * The store holds **only observed facts**: which event code hash was heard, in
 * which ENIN windows, and how often. It holds no event definition, no verdict
 * about whether an event is currently running, and no ranking.
 *
 * Two properties of this type are contract, not implementation detail:
 *
 * 1. **It annotates, it never filters.** beid#139 requires each of its three
 *    anti-spoofing layers to be independently disableable. A store that drops
 *    candidates makes the dropped layer impossible to turn off, because the
 *    caller can no longer see what was removed. Every retained event is
 *    returned by [eventInfoCandidates]; applying a layer is the caller's job.
 * 2. **It stores no time-dependent judgement.** "Is this event running right
 *    now" is deliberately absent. Computed when a hint arrives it would be
 *    permanently wrong for an event first heard before its own start window.
 *    The window bounds are carried as facts and the predicate is evaluated at
 *    read time by [isEventWindowOpen].
 */
public class EventInfoStore internal constructor(
    internal val records: MutableMap<String, EventObservationRecord> = mutableMapOf(),
) {
    internal var omittedEventObserved: Boolean = false

    public val retainedEventCount: Int
        get() = records.size

    /**
     * True once a hint for a 33rd distinct event was rejected for capacity.
     *
     * Surfaced rather than silently swallowed so a caller can tell "these are
     * all the nearby events" apart from "these are the first 32 of them".
     */
    public val hasOmittedEvents: Boolean
        get() = omittedEventObserved
}

/**
 * The facts about one event definition that a candidate needs.
 *
 * This is deliberately **not** `EventDefinition`. The registry-decoded
 * `EventDefinition/v1` and its retrieval path are owned by beid#108 and do not
 * exist yet; this type is the four fields this slice consumes, so that #108 can
 * later supply them without either side renaming a Swift-exported symbol.
 *
 * `eninStart` and `eninEnd` are ENIN **window indices**, not epoch seconds. The
 * registry payload encodes them as unsigned 64-bit; this type holds them as
 * signed [Long] and [createEventDefinitionFacts] rejects negatives. Values above
 * `Long.MAX_VALUE` are therefore not representable — at a 300-second window that
 * is roughly 8.8e13 years away, but it is an assumption and not a proof.
 */
public class EventDefinitionFacts internal constructor(
    public val eventCodeHashHex: String,
    public val displayName: String,
    public val eninStart: Long,
    public val eninEnd: Long,
)

/**
 * One nearby event, with the facts needed to judge it, and nothing judged.
 *
 * `definition` is null when no supplied definition matched this event's hash.
 * That null is the honest third state of the time-window layer: not "outside the
 * window" but "there is nothing to compare against". Callers get the tri-state
 * from optional binding rather than from a boolean that has to encode it.
 */
public class EventCandidate internal constructor(
    public val eventCodeHashHex: String,
    public val firstSeenWindowIndex: Long,
    public val lastSeenWindowIndex: Long,
    public val observationCount: Int,
    public val definition: EventDefinitionFacts?,
    public val relayCount: RelayCount?,
) {
    /** beid#141's "match against the definition is explicit" fact. */
    public val isDefinitionMatched: Boolean
        get() = definition != null

    /**
     * Null until a definition matches.
     *
     * The name a B005 hint carries is unauthenticated and is never shown; per
     * beid#141 only an event matched against its registry definition is
     * rendered, and the name shown is the definition's.
     */
    public val displayName: String?
        get() = definition?.displayName
}

/**
 * How many devices relayed an event — **absent, not zero, when unknown**.
 *
 * This exists as a nullable box rather than a plain `Int` because the two states
 * are different claims and only one of them is currently true. Zero asserts
 * "nobody relayed this". Absent says "we cannot know". Barnard 0.3.0's B005
 * receive API carries no relayer identity at all: the discovery session retains
 * event code hash to display-name sets and reports three booleans, so a relay
 * count cannot be derived from it. That is filed as levarac/barnard#128.
 *
 * Today [EventCandidate.relayCount] is therefore **always null**. Do not
 * substitute a zero to make a call site simpler, and do not synthesize a count
 * from peripheral identity observed in beid's own scan layer — that workaround
 * is explicitly ruled out pending a decision, and it would only approximate a
 * device count anyway, because proximity identifiers rotate per ENIN window and
 * one device is counted afresh in every window it is heard in.
 */
public class RelayCount internal constructor(
    public val value: Int,
)

/** Sparse candidate set. Order is defined by [eventInfoCandidates]. */
public class EventCandidates internal constructor(
    internal val candidates: List<EventCandidate>,
) {
    public val candidateCount: Int
        get() = candidates.size

    public fun candidateAt(index: Int): EventCandidate? = candidates.getOrNull(index)
}

/** Swift-exportable builder for the definitions available at read time. */
public class EventDefinitionInput internal constructor(
    internal val definitions: MutableMap<String, EventDefinitionFacts> = mutableMapOf(),
) {
    public val definitionCount: Int
        get() = definitions.size
}

public fun createEventInfoStore(): EventInfoStore = EventInfoStore()

/**
 * Records that a B005 hint for [eventCodeHashHex] was heard in [windowIndex].
 *
 * Returns false when the observation is rejected at the boundary: a hash that is
 * not 16 hex characters, a negative window index, or a new event beyond
 * [MAX_RETAINED_EVENT_COUNT] (which also sets [EventInfoStore.hasOmittedEvents]).
 * Hex input is lowercased before use, so two platforms that hexify with
 * different case cannot split one event into two candidates.
 *
 * Barnard's overflow marker — an empty display name with an empty event code
 * hash — is rejected by the hash shape check alone, so it never becomes a
 * candidate. No Barnard semantics are re-checked here: length and container
 * shape are the only things this boundary is permitted to judge (KMP-002).
 *
 * **The hint's own display name is deliberately not a parameter.** Its validity
 * is Barnard's to enforce and re-checking it here would duplicate the SDK, and
 * its value is never rendered, because beid#141 shows only the definition's
 * name. Recording it would create a second, unauthenticated name for the same
 * event with no consumer.
 *
 * First and last window are kept as min and max rather than as written order, so
 * feeding the same observations in a different order yields the same candidate.
 */
public fun recordEventInfoHint(
    store: EventInfoStore,
    eventCodeHashHex: String,
    windowIndex: Long,
): Boolean {
    if (windowIndex < 0L) {
        return false
    }
    val key = eventCodeHashHex.normalizedEventCodeHashHexOrNull() ?: return false

    val existing = store.records[key]
    if (existing == null) {
        if (store.records.size >= MAX_RETAINED_EVENT_COUNT) {
            store.omittedEventObserved = true
            return false
        }
        store.records[key] = EventObservationRecord(
            eventCodeHashHex = key,
            firstSeenWindowIndex = windowIndex,
            lastSeenWindowIndex = windowIndex,
            observationCount = 1,
        )
        return true
    }

    if (windowIndex < existing.firstSeenWindowIndex) {
        existing.firstSeenWindowIndex = windowIndex
    }
    if (windowIndex > existing.lastSeenWindowIndex) {
        existing.lastSeenWindowIndex = windowIndex
    }
    existing.observationCount += 1
    return true
}

public fun createEventDefinitionInput(): EventDefinitionInput = EventDefinitionInput()

/**
 * Builds the definition facts, or null when the shape is unusable.
 *
 * Rejects a malformed hash, an empty or over-long display name, a negative
 * window bound, and a range whose start is after its end. An inverted range is
 * rejected here rather than being allowed to produce a window that is never open,
 * because "no candidate is ever inside this event" and "this definition is
 * broken" are different answers and only one of them is actionable.
 */
public fun createEventDefinitionFacts(
    eventCodeHashHex: String,
    displayName: String,
    eninStart: Long,
    eninEnd: Long,
): EventDefinitionFacts? {
    val key = eventCodeHashHex.normalizedEventCodeHashHexOrNull() ?: return null
    if (!displayName.isValidEventDisplayName()) {
        return null
    }
    if (eninStart < 0L || eninEnd < 0L || eninStart > eninEnd) {
        return null
    }
    return EventDefinitionFacts(
        eventCodeHashHex = key,
        displayName = displayName,
        eninStart = eninStart,
        eninEnd = eninEnd,
    )
}

/**
 * Adds one definition to the read-time set, replacing any earlier definition for
 * the same event. Returns false when the shape is rejected.
 */
public fun addEventDefinition(
    input: EventDefinitionInput,
    eventCodeHashHex: String,
    displayName: String,
    eninStart: Long,
    eninEnd: Long,
): Boolean {
    val facts = createEventDefinitionFacts(
        eventCodeHashHex = eventCodeHashHex,
        displayName = displayName,
        eninStart = eninStart,
        eninEnd = eninEnd,
    ) ?: return false
    input.definitions[facts.eventCodeHashHex] = facts
    return true
}

/**
 * Joins observed events with the supplied definitions and returns every one.
 *
 * The join happens here, at read time, rather than when a hint arrives: a
 * definition may be retrieved long after the event was first heard, and pinning
 * the match at receive time would leave an event permanently unmatched for no
 * reason other than arrival order.
 *
 * Candidates whose hash matched no definition are still returned, with a null
 * definition. Dropping them here would silently implement beid#141's "do not
 * show unregistered events" rule inside the store, which is exactly the
 * pre-filtering that makes a layer impossible to disable.
 *
 * Order is by event code hash ascending. That ordering is **deterministic and
 * deliberately meaningless** — it is not a ranking. Ranking discovered
 * candidates is a separate decision that KMP-003 keeps out of this slice until
 * the beid#100 owner has acknowledged its interface, and returning them in a
 * plausible-looking order would be an unratified ranking in all but name.
 */
public fun eventInfoCandidates(
    store: EventInfoStore,
    definitions: EventDefinitionInput,
): EventCandidates =
    EventCandidates(
        candidates = store.records.keys.sorted().map { key ->
            val record = store.records.getValue(key)
            EventCandidate(
                eventCodeHashHex = record.eventCodeHashHex,
                firstSeenWindowIndex = record.firstSeenWindowIndex,
                lastSeenWindowIndex = record.lastSeenWindowIndex,
                observationCount = record.observationCount,
                definition = definitions.definitions[key],
                // Always null: see RelayCount. Never replace this with 0.
                relayCount = null,
            )
        },
    )

private fun String.normalizedEventCodeHashHexOrNull(): String? {
    if (length != EVENT_CODE_HASH_HEX_LENGTH) {
        return null
    }
    val lowercase = lowercase()
    if (!lowercase.all { it in '0'..'9' || it in 'a'..'f' }) {
        return null
    }
    return lowercase
}

private fun String.isValidEventDisplayName(): Boolean {
    if (isEmpty()) {
        return false
    }
    return try {
        encodeToByteArray(throwOnInvalidSequence = true).size <= MAX_EVENT_DISPLAY_NAME_BYTES
    } catch (_: Exception) {
        false
    }
}

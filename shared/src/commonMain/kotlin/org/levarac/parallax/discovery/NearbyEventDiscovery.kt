package org.levarac.parallax.discovery

import org.levarac.parallax.registry.EventJoinMode
import org.levarac.parallax.registry.eventCodeHashForOpenEventV1

private const val DISCOVERY_TTL_MILLIS: Long = 300_000L

/**
 * How long a failed registry resolution waits before it may be tried again
 * (beid#584). Element `n` is the wait after the `n`-th consecutive failure;
 * every failure past the end of the list waits
 * [STEADY_REGISTRY_RETRY_INTERVAL_MILLIS].
 *
 * Deliberately short and then flat. The first two entries cover the case this
 * was written for, a read that failed for a reason that clears by itself, and
 * the flat tail is what keeps a beacon that is simply not registered from
 * turning into a request per hint against the operator endpoint. It is here
 * rather than in either host so iOS and Android retry the same candidate at
 * the same times.
 */
private val REGISTRY_RETRY_BACKOFF_MILLIS: LongArray = longArrayOf(5_000L, 30_000L)
private const val STEADY_REGISTRY_RETRY_INTERVAL_MILLIS: Long = 120_000L
private const val EVENT_CODE_HASH_BYTES: Int = 8
private const val MAX_LIVE_SOURCE_COUNT: Int = 256

/** A B005 hint is useful for discovery, but is not authenticated event identity. */
public enum class NearbyEventTrustStatus {
    UNAUTHENTICATED_B005_HINT,
}

/**
 * Registry state for a nearby hint. The hash-to-event-ID lookup is
 * operator-attested routing, not a cryptographic binding. Only
 * [REGISTERED_VIA_OPERATOR_LOOKUP] means the routed ID subsequently passed
 * the registry's full on-chain and authority-signature definition verification,
 * explicitly declared open admission, and matched the B005 hash both in its
 * signed field and in an independent recomputation from the complete Event ID.
 */
public enum class NearbyEventRegistryStatus {
    UNRESOLVED,
    LOOKUP_UNAVAILABLE,
    NOT_REGISTERED,
    REGISTERED_VIA_OPERATOR_LOOKUP,
}

public enum class NearbyEventRegistryResolutionResult {
    LOOKUP_UNAVAILABLE, NOT_REGISTERED, VERIFICATION_UNAVAILABLE, VERIFIED,
}

/**
 * Barnard's three-tier B005 v2 receiver state (spec 122, "Receiver policy"),
 * mirrored 1:1 into shared discovery state.
 *
 * This answers "is this envelope verified", which is a different question from
 * [NearbyEventRegistryStatus]'s "does a definition exist for this hash". A
 * candidate can be registered without ever having carried a v2 envelope, and
 * an envelope can be radio-self-verified for a hash the registry does not know.
 *
 * - [UNVERIFIED] is the default, and the only state a candidate assembled from
 *   v1 `eventInfoHint` traffic alone can ever reach. A v2 container whose
 *   receipt is unverified carries no parsed identity at all -- barnard's
 *   `verify` returns nothing for both a malformed container and a bad
 *   signature -- so it has no event-code hash to key on and never becomes a
 *   candidate here.
 * - [RADIO_SELF_VERIFIED] means barnard's own signature and self-consistency
 *   checks passed. Registration is NOT confirmed and this MUST NOT be shown to
 *   a user as "verified".
 * - [REGISTRY_VERIFIED] is assigned only by this host, and only after its own
 *   authenticated registry read agreed with the envelope through barnard's
 *   pure `registryAgreement`. The SDK never assigns it.
 *
 * The state is monotonically raised within one discovery session and is
 * cleared with the rest of the session by TTL expiry or reset: a later
 * observation, including a hostile one, can never lower a tier already
 * established for a hash.
 *
 * ## Which gate applies to which candidate
 *
 * The join / key-use / recording / relay gate is split by whether a candidate
 * has ever carried a v2 envelope, because the two kinds of candidate cannot be
 * held to the same bar:
 *
 * - **A candidate with a v2 envelope observed** ([RADIO_SELF_VERIFIED] or
 *   above) must reach [REGISTRY_VERIFIED]. [RADIO_SELF_VERIFIED] is never
 *   enough, and must never be presented to a user as "verified".
 * - **A candidate assembled from v1 `eventInfoHint` traffic alone** stays at
 *   [UNVERIFIED] forever, since nothing can raise it, and so keeps the
 *   pre-existing [NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP]
 *   gate. Holding it to [REGISTRY_VERIFIED] would make it permanently unable
 *   to pass that operator-lookup gate and regress the shipped v1 join path.
 *   That gate is the typed-code path — `operatorLookupJoinEligibility` and
 *   `RegistryVerifiedJoinContext.fromOperatorLookup` — not the nearby-candidate
 *   path this state feeds, and the two answer different questions.
 *
 * This split is temporary by design. It exists only while v1 traffic is still
 * the common case; once organizers serve their own v2 containers, the v1
 * fallback retires and the single [REGISTRY_VERIFIED] bar applies to every
 * candidate. A host must not build anything on the v1 branch surviving.
 */
public enum class NearbyEventReceiverState {
    UNVERIFIED,
    RADIO_SELF_VERIFIED,
    REGISTRY_VERIFIED,
}

/** One peripheral's latest B005 facts for one event-code hash. */
public class NearbyEventSourceObservation internal constructor(
    public val peripheralId: String,
    public val eventDisplayName: String,
    census: ByteArray?,
    public val firstSeenAtEpochMillis: Long,
    public val lastSeenAtEpochMillis: Long,
) {
    private val censusBytes: ByteArray? = census?.copyOf()

    /** Returns a defensive copy so a published snapshot remains immutable. */
    public val census: ByteArray?
        get() = censusBytes?.copyOf()
}

/** One nearby event candidate assembled from every live source for its exact hash. */
public class NearbyEventCandidate internal constructor(
    eventCodeHash: ByteArray,
    public val firstSeenAtEpochMillis: Long,
    public val lastSeenAtEpochMillis: Long,
    private val sources: List<NearbyEventSourceObservation>,
    private val displayNames: List<String>,
    public val registryStatus: NearbyEventRegistryStatus,
    public val resolvedEventIdHex: String?,
    public val receiverState: NearbyEventReceiverState,
    /**
     * The Event Definition digest this candidate's registration was
     * established against, or null when no resolution has matched for it
     * (beid#374). See [RegistryRecord.definitionHashHex] for why an Event ID
     * alone is not enough for a join to stand on.
     */
    public val verifiedDefinitionHashHex: String?,
    /** The pinned registry block behind [verifiedDefinitionHashHex]. */
    public val registryBlockHashHex: String?,
    /** The verified definition's validity window, re-checked when a join is issued. */
    public val definitionValidFromEpochSeconds: Long?,
    public val definitionValidUntilEpochSeconds: Long?,
    /**
     * How many resolutions for this candidate have failed in a row, and when
     * the next one becomes eligible, or null when none is scheduled
     * (beid#584).
     *
     * Diagnostic and scheduling state, never a gate: [registryStatus] remains
     * the only answer to whether this candidate is registered. A host reads
     * the deadline to wake itself at the right time and to say, in one log
     * line, when it will try again — the question the field capture behind
     * this issue could not answer.
     */
    public val registryResolutionFailureCount: Int,
    public val registryRetryAtEpochMillis: Long?,
    rawEnvelopeContainer: ByteArray?,
) {
    private val eventCodeHashBytes: ByteArray = eventCodeHash.copyOf()
    private val rawEnvelopeContainerBytes: ByteArray? = rawEnvelopeContainer?.copyOf()

    /**
     * The B005 v2 container exactly as it came off the wire, for the last
     * radio-self-verified envelope observed for this hash, or null when this
     * candidate has only ever carried v1 hints.
     *
     * Retained because spec 134 re-broadcast is signature-preserving: a relay
     * serves these bytes back with only `relayHopCount` changed, never a
     * re-encode and never a re-signing, and the later relay verifier needs the
     * exact bytes too. Session state only, held for the discovery TTL and
     * dropped on expiry or reset; nothing here is persisted.
     *
     * Returns a defensive copy, like every other byte accessor on this type:
     * the bytes are what a signature was computed over and must not be
     * mutable in place after the fact.
     */
    public val rawEnvelopeContainer: ByteArray?
        get() = rawEnvelopeContainerBytes?.copyOf()

    /** Lowercase hex encoding of [rawEnvelopeContainer], for native callers. */
    public val rawEnvelopeContainerHex: String?
        get() = rawEnvelopeContainerBytes?.joinToString(separator = "") {
            (it.toInt() and 0xff).toString(16).padStart(2, '0')
        }

    /** Returns a defensive copy so callers cannot mutate candidate identity. */
    public val eventCodeHash: ByteArray
        get() = eventCodeHashBytes.copyOf()

    /**
     * Lowercase hex encoding of [eventCodeHash], for native callers that need
     * the string form (e.g. a registry lookup key) without touching Swift
     * Export's `kotlin.ByteArray` element accessors directly.
     */
    public val eventCodeHashHex: String
        get() = eventCodeHashBytes.joinToString(separator = "") {
            (it.toInt() and 0xff).toString(16).padStart(2, '0')
        }

    public val sourceCount: Int
        get() = sources.size

    public fun sourceAt(index: Int): NearbyEventSourceObservation? = sources.getOrNull(index)

    public val distinctDisplayNameCount: Int
        get() = displayNames.size

    public fun displayNameAt(index: Int): String? = displayNames.getOrNull(index)

    public val hasDisplayNameConflict: Boolean
        get() = displayNames.size > 1

    public val trustStatus: NearbyEventTrustStatus
        get() = NearbyEventTrustStatus.UNAUTHENTICATED_B005_HINT

}

/** Immutable, deterministically ordered view of the current discovery session. */
public class NearbyEventCandidates internal constructor(
    private val candidates: List<NearbyEventCandidate>,
    public val additionalNamesOmitted: Boolean,
    public val additionalEventsOmitted: Boolean,
    public val hasLocallyEvictedSources: Boolean,
    public val nextExpiryAtEpochMillis: Long?,
    /**
     * The earliest moment any candidate's failed resolution may be retried,
     * or null when none is scheduled (beid#584). A host with a timer wakes on
     * the earlier of this and [nextExpiryAtEpochMillis]; one without simply
     * retries at its next observation.
     */
    public val nextRegistryRetryAtEpochMillis: Long?,
    /** See [NearbyEventDiscoveryStore.unverifiedEnvelopeCount]. */
    public val unverifiedEnvelopeCount: Int,
) {
    public val candidateCount: Int
        get() = candidates.size

    public fun candidateAt(index: Int): NearbyEventCandidate? = candidates.getOrNull(index)
}

/** Result of applying one hint, time refresh, or reset to a discovery store. */
public class NearbyEventDiscoveryUpdate internal constructor(
    public val acceptedHint: Boolean,
    public val changed: Boolean,
    public val snapshot: NearbyEventCandidates,
)

/**
 * Observer-local B005 discovery state.
 *
 * This type is single-threaded by contract. Native lifecycle owners must confine
 * mutation to their event-delivery context and publish only [snapshot].
 */
public class NearbyEventDiscoveryStore internal constructor() {
    internal val sources: MutableMap<SourceKey, MutableSourceRecord> = mutableMapOf()
    internal var additionalNamesOmittedAtEpochMillis: Long? = null
    internal var additionalEventsOmittedAtEpochMillis: Long? = null
    internal var locallyEvictedSources: Boolean = false
    internal val registry: MutableMap<EventHash, RegistryRecord> = mutableMapOf()

    /**
     * Held apart from [registry] on purpose. A [RegistryRecord] is rewritten
     * every time a resolution completes, including the retries beid#584
     * added, and a receiver state stored inside it would be downgraded by an
     * ordinary re-observation after a flaky registry read. The tier a hash
     * has reached is not a property of any one registry attempt.
     */
    internal val receiverStates: MutableMap<EventHash, NearbyEventReceiverState> = mutableMapOf()

    /**
     * Signature-preserving relay needs the exact container bytes, so they are
     * held for the session beside the tier they belong to. Same lifetime as
     * [receiverStates]: dropped on TTL expiry and on reset, never persisted.
     */
    internal val rawEnvelopeContainers: MutableMap<EventHash, ByteArray> = mutableMapOf()

    /**
     * How many B005 v2 containers this session saw that barnard could not
     * verify. Such a container has no parsed identity and becomes no
     * candidate, so this tally is the only trace it leaves; it exists so a
     * dropped envelope is observable in tests and in a host's diagnostics
     * rather than vanishing silently. A session tally, cleared by reset like
     * the eviction fact, not by TTL.
     */
    internal var unverifiedEnvelopeCount: Int = 0

    public val snapshot: NearbyEventCandidates
        get() = buildSnapshot()
}

internal data class RegistryRecord(
    var status: NearbyEventRegistryStatus = NearbyEventRegistryStatus.UNRESOLVED,
    var eventIdHex: String? = null,
    var attempt: NearbyEventRegistryResolutionAttempt? = null,
    /**
     * The Event Definition digest and pinned block this hash's registration
     * was established against (beid#374).
     *
     * Retained because a later join has to prove it is joining *the same*
     * definition that promoted this candidate, and an Event ID alone cannot
     * prove that: the same ID can be read again later against a different
     * definition or a different block. Both are set only when the resolution
     * actually matched, and both are cleared with the rest of the record, so
     * a failed retry cannot leave a stale digest standing behind an
     * unresolved status.
     */
    var definitionHashHex: String? = null,
    var registryBlockHashHex: String? = null,
    /**
     * The definition's validity window as the registration established it.
     *
     * Retained alongside the digest because the join issuer re-checks the
     * window *at issue time*, not at promotion time. Retained evidence
     * establishes what was verified; the re-check establishes that it is still
     * true. Without the window on the candidate, a promotion made hours ago
     * could still issue a join for a definition that has since expired.
     */
    var definitionValidFromEpochSeconds: Long? = null,
    var definitionValidUntilEpochSeconds: Long? = null,
    /**
     * How many resolutions for this hash have come back NOT_REGISTERED or
     * LOOKUP_UNAVAILABLE in a row, and when the next one may start (beid#584).
     *
     * [failedResolutionCount] only ever grows within a session, so the
     * backoff cannot be reset by a beacon that keeps re-appearing. Both are
     * cleared by a resolution that stands, and both die with the record on
     * TTL expiry or reset — a candidate that leaves and comes back genuinely
     * starts over.
     *
     * [retryDue] rather than a return to [NearbyEventRegistryStatus.UNRESOLVED]
     * because the status is what the card shows: resetting it would put the
     * card back to "Checking" between attempts, which is the state beid#584
     * exists to get rid of.
     */
    var failedResolutionCount: Int = 0,
    var retryDue: Boolean = false,
    var nextRetryAtEpochMillis: Long? = null,
)

/**
 * Opaque identity for one native registry lookup and verification attempt.
 *
 * Native callers must return this exact object with the eventual completion.
 * A reset or TTL expiry removes the record that owns it, so a late completion
 * cannot attach to a newer attempt for the same B005 hash.
 */
public class NearbyEventRegistryResolutionAttempt internal constructor(
    internal val eventHash: EventHash,
)

internal class EventHash(bytes: ByteArray) : Comparable<EventHash> {
    private val value: ByteArray = bytes.copyOf()

    fun copyBytes(): ByteArray = value.copyOf()

    override fun compareTo(other: EventHash): Int {
        for (index in value.indices) {
            val comparison = (value[index].toInt() and 0xff)
                .compareTo(other.value[index].toInt() and 0xff)
            if (comparison != 0) return comparison
        }
        return 0
    }

    override fun equals(other: Any?): Boolean =
        other is EventHash && value.contentEquals(other.value)

    override fun hashCode(): Int = value.contentHashCode()
}

internal data class SourceKey(
    val eventHash: EventHash,
    val peripheralId: String,
)

internal class MutableSourceRecord(
    val eventHash: EventHash,
    val peripheralId: String,
    var eventDisplayName: String,
    census: ByteArray?,
    var firstSeenAtEpochMillis: Long,
    var lastSeenAtEpochMillis: Long,
) {
    private var censusBytes: ByteArray? = census?.copyOf()

    fun censusCopy(): ByteArray? = censusBytes?.copyOf()

    fun replaceCensus(census: ByteArray?) {
        censusBytes = census?.copyOf()
    }
}

public fun createNearbyEventDiscoveryStore(): NearbyEventDiscoveryStore =
    NearbyEventDiscoveryStore()

/**
 * Records one B005 observation after enforcing only the shared boundary shape.
 *
 * Display-name and census semantics remain Barnard-owned. Omission facts are
 * processed before candidate identity validation so Barnard's empty overflow
 * marker can update them without becoming a candidate.
 */
public fun recordNearbyEventHint(
    store: NearbyEventDiscoveryStore,
    peripheralId: String,
    eventDisplayName: String,
    eventCodeHash: ByteArray,
    census: ByteArray?,
    additionalNamesOmitted: Boolean,
    additionalEventsOmitted: Boolean,
    observedAtEpochMillis: Long,
): NearbyEventDiscoveryUpdate = recordObservation(
    store = store,
    peripheralId = peripheralId,
    eventDisplayName = eventDisplayName,
    eventCodeHash = eventCodeHash,
    census = census,
    censusProvided = true,
    additionalNamesOmitted = additionalNamesOmitted,
    additionalEventsOmitted = additionalEventsOmitted,
    observedAtEpochMillis = observedAtEpochMillis,
)

/**
 * Records one B005 v2 observation whose receipt was `RADIO_SELF_VERIFIED`.
 *
 * The host does not decode the container: barnard has already verified the
 * signature and the self-consistency of `eventId`, and these are the fields it
 * parsed out. Source bookkeeping is identical to [recordNearbyEventHint] --
 * the same TTL, eviction, omission and identity rules apply -- and the only
 * added effect is raising this hash's [NearbyEventReceiverState] to
 * [NearbyEventReceiverState.RADIO_SELF_VERIFIED].
 *
 * A v2 envelope carries no census, so this never clears a census a v1 hint
 * already recorded for the same source.
 *
 * A receipt that is not radio-self-verified must not reach here at all: it has
 * no parsed event-code hash to key on, and so has no candidate to describe.
 *
 * [agreesWithRegistry] is barnard's `registryAgreement` for THIS envelope
 * against a definition the host had already read for this hash, or false when
 * the host has no such definition yet. It decides two things, so no caller has
 * to remember a second call: whether this envelope may replace the container
 * retained for a hash that is already
 * [NearbyEventReceiverState.REGISTRY_VERIFIED], and, when the hash is already
 * registered via operator lookup, whether this envelope promotes it. Promotion
 * still runs through the same guard
 * [applyNearbyEventRegistryAgreementFromHex] uses, so an envelope can never
 * promote a hash the registry has not vouched for.
 *
 * An empty [rawContainer] is rejected rather than stored. Zero bytes are not
 * what came off the wire, and a spec 134 relay re-sending an empty container
 * is worse than one relaying nothing: the candidate would claim to hold bytes
 * it does not have. Such a call is counted as a drop, exactly as a
 * verification failure is.
 */
public fun recordNearbyEventRadioSelfVerifiedEnvelope(
    store: NearbyEventDiscoveryStore,
    peripheralId: String,
    eventDisplayName: String,
    eventCodeHash: ByteArray,
    rawContainer: ByteArray,
    agreesWithRegistry: Boolean,
    additionalNamesOmitted: Boolean,
    additionalEventsOmitted: Boolean,
    observedAtEpochMillis: Long,
): NearbyEventDiscoveryUpdate {
    if (rawContainer.isEmpty()) return recordNearbyEventUnverifiedEnvelope(store)
    val update = recordObservation(
        store = store,
        peripheralId = peripheralId,
        eventDisplayName = eventDisplayName,
        eventCodeHash = eventCodeHash,
        census = null,
        censusProvided = false,
        additionalNamesOmitted = additionalNamesOmitted,
        additionalEventsOmitted = additionalEventsOmitted,
        observedAtEpochMillis = observedAtEpochMillis,
    )
    if (!update.acceptedHint) return update
    val hash = EventHash(eventCodeHash)
    val raised = store.raiseReceiverState(hash, NearbyEventReceiverState.RADIO_SELF_VERIFIED)
    // Below REGISTRY_VERIFIED the newest container simply wins: spec 134
    // elects by hop among what a device can currently observe, so the freshest
    // bytes are what a relay decision should be made from, and an older copy
    // of the same event is not more authoritative for being older.
    //
    // At REGISTRY_VERIFIED that rule would be a hole. Barnard's radio
    // self-check is satisfied by any envelope that is internally consistent,
    // including one carrying a different key set for the same event-code hash.
    // Such an envelope cannot lower the tier and its disagreement is dropped
    // by `promoteToRegistryVerified`'s tier guard, so under a newest-wins rule
    // it would quietly replace the retained bytes and leave a candidate
    // reading REGISTRY_VERIFIED while holding bytes no registry read ever
    // vouched for -- the exact bytes a spec 134 relay re-sends. So once the
    // tier is REGISTRY_VERIFIED, only an envelope that itself agrees with the
    // registry may replace what is held. A genuine relayed copy of the same
    // envelope still qualifies: `registryAgreement` compares the signed
    // fields, and `relayHopCount` is not one of them.
    val registryVerified = store.receiverStates[hash] == NearbyEventReceiverState.REGISTRY_VERIFIED
    val mayReplaceContainer = !registryVerified || agreesWithRegistry
    val containerChanged = mayReplaceContainer &&
        !store.rawEnvelopeContainers[hash].contentEqualsOrNull(rawContainer)
    if (containerChanged) store.rawEnvelopeContainers[hash] = rawContainer.copyOf()
    // Folded in so a caller cannot record an agreeing envelope and forget to
    // promote it. A hash resolves against the registry exactly once, so an
    // envelope arriving after that completion has no callback left to ride on,
    // and this is the only place left that can act on its verdict. The guard
    // is the shared one: no promotion without a registry read that already
    // published REGISTERED_VIA_OPERATOR_LOOKUP for this hash.
    val promoted = store.promoteToRegistryVerified(hash, agreesWithRegistry)
    if (!raised && !containerChanged && !promoted) return update
    return NearbyEventDiscoveryUpdate(
        acceptedHint = true,
        changed = true,
        snapshot = store.snapshot,
    )
}

/**
 * Records that barnard could not verify a B005 v2 container.
 *
 * There is nothing else to record: `verify` returns nothing for both a
 * malformed container and a bad signature, so the container has no event-code
 * hash, no display name, and no candidate to attach to. Counting it is what
 * keeps a dropped envelope observable instead of silent.
 *
 * Reports `changed = false`, because no candidate, source, omission fact or
 * expiry time moved. Publish the returned snapshot if you surface the tally,
 * but do not rebuild cards or re-arm the expiry wake-up from it: a peer
 * transmitting garbage would otherwise drive both on every received packet,
 * and re-arming from a snapshot whose expiry times did not change is how a
 * scheduled refresh gets pushed around by traffic that means nothing.
 */
public fun recordNearbyEventUnverifiedEnvelope(
    store: NearbyEventDiscoveryStore,
): NearbyEventDiscoveryUpdate {
    store.unverifiedEnvelopeCount += 1
    return NearbyEventDiscoveryUpdate(
        acceptedHint = false,
        changed = false,
        snapshot = store.snapshot,
    )
}

private fun ByteArray?.contentEqualsOrNull(other: ByteArray): Boolean =
    this != null && this.contentEquals(other)

/** Swift Export boundary for [recordNearbyEventRadioSelfVerifiedEnvelope]. */
public fun recordNearbyEventRadioSelfVerifiedEnvelopeFromHex(
    store: NearbyEventDiscoveryStore,
    peripheralId: String,
    eventDisplayName: String,
    eventCodeHashHex: String,
    rawContainerHex: String,
    agreesWithRegistry: Boolean,
    additionalNamesOmitted: Boolean,
    additionalEventsOmitted: Boolean,
    observedAtEpochMillis: Long,
): NearbyEventDiscoveryUpdate {
    // A container that does not survive the hex boundary is rejected and
    // counted, for the same reason a verification failure is: it is the only
    // trace the envelope can leave. An empty result is rejected one layer
    // down, in the byte-taking entry, so a host calling that directly
    // inherits the same rule.
    val eventCodeHash = runCatching { eventCodeHashHex.decodeHexBytes() }.getOrNull()
    val rawContainer = runCatching { rawContainerHex.decodeHexBytes() }.getOrNull()
    if (eventCodeHash == null || rawContainer == null) {
        return recordNearbyEventUnverifiedEnvelope(store)
    }
    return recordNearbyEventRadioSelfVerifiedEnvelope(
        store = store,
        peripheralId = peripheralId,
        eventDisplayName = eventDisplayName,
        eventCodeHash = eventCodeHash,
        rawContainer = rawContainer,
        agreesWithRegistry = agreesWithRegistry,
        additionalNamesOmitted = additionalNamesOmitted,
        additionalEventsOmitted = additionalEventsOmitted,
        observedAtEpochMillis = observedAtEpochMillis,
    )
}

/**
 * Promotes one hash to [NearbyEventReceiverState.REGISTRY_VERIFIED].
 *
 * [agrees] is the verdict of barnard's pure `registryAgreement(verified,
 * definition)`, run by the host against the definition its own authenticated
 * registry read returned. Promotion additionally requires that this host has
 * already published [NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP]
 * for the hash and that the hash is currently
 * [NearbyEventReceiverState.RADIO_SELF_VERIFIED]. Disagreement, an absent
 * envelope, an absent or unverified registry read, and a resolution that
 * arrived for a session that has since been reset or expired all leave the
 * state untouched.
 *
 * Exposed separately from [completeNearbyEventRegistryResolutionFromHex]
 * because the two inputs arrive in either order: the registry resolution for a
 * hash starts on its first v1 hint and completes exactly once, so an envelope
 * that lands after that completion has no resolution callback left to ride on.
 */
public fun applyNearbyEventRegistryAgreementFromHex(
    store: NearbyEventDiscoveryStore,
    eventCodeHashHex: String,
    agrees: Boolean,
): NearbyEventDiscoveryUpdate {
    val bytes = runCatching { eventCodeHashHex.decodeHexBytes() }.getOrNull()
    if (bytes == null || bytes.size != EVENT_CODE_HASH_BYTES) {
        return NearbyEventDiscoveryUpdate(false, false, store.snapshot)
    }
    val changed = store.promoteToRegistryVerified(EventHash(bytes), agrees)
    return NearbyEventDiscoveryUpdate(false, changed, store.snapshot)
}

internal fun NearbyEventDiscoveryStore.raiseReceiverState(
    hash: EventHash,
    state: NearbyEventReceiverState,
): Boolean {
    if (sources.keys.none { it.eventHash == hash }) return false
    val current = receiverStates[hash] ?: NearbyEventReceiverState.UNVERIFIED
    if (current.ordinal >= state.ordinal) return false
    receiverStates[hash] = state
    return true
}

internal fun NearbyEventDiscoveryStore.promoteToRegistryVerified(
    hash: EventHash,
    agrees: Boolean,
): Boolean {
    if (!agrees) return false
    if (registry[hash]?.status != NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP) return false
    if (receiverStates[hash] != NearbyEventReceiverState.RADIO_SELF_VERIFIED) return false
    return raiseReceiverState(hash, NearbyEventReceiverState.REGISTRY_VERIFIED)
}

private fun recordObservation(
    store: NearbyEventDiscoveryStore,
    peripheralId: String,
    eventDisplayName: String,
    eventCodeHash: ByteArray,
    census: ByteArray?,
    censusProvided: Boolean,
    additionalNamesOmitted: Boolean,
    additionalEventsOmitted: Boolean,
    observedAtEpochMillis: Long,
): NearbyEventDiscoveryUpdate {
    if (observedAtEpochMillis < 0L) {
        return NearbyEventDiscoveryUpdate(
            acceptedHint = false,
            changed = false,
            snapshot = store.snapshot,
        )
    }

    var changed = expireAt(store, observedAtEpochMillis)
    changed = updateOmissionFacts(
        store = store,
        additionalNamesOmitted = additionalNamesOmitted,
        additionalEventsOmitted = additionalEventsOmitted,
        observedAtEpochMillis = observedAtEpochMillis,
    ) || changed

    if (peripheralId.isBlank() || eventCodeHash.size != EVENT_CODE_HASH_BYTES) {
        return NearbyEventDiscoveryUpdate(
            acceptedHint = false,
            changed = changed,
            snapshot = store.snapshot,
        )
    }

    val eventHash = EventHash(eventCodeHash)
    val key = SourceKey(eventHash, peripheralId)
    val existing = store.sources[key]
    if (existing == null) {
        if (store.sources.size >= MAX_LIVE_SOURCE_COUNT) {
            val evicted = store.sources.values.minWithOrNull(sourceEvictionComparator)
            if (evicted != null) {
                store.sources.remove(SourceKey(evicted.eventHash, evicted.peripheralId))
                store.locallyEvictedSources = true
            }
        }
        store.sources[key] = MutableSourceRecord(
            eventHash = eventHash,
            peripheralId = peripheralId,
            eventDisplayName = eventDisplayName,
            census = census,
            firstSeenAtEpochMillis = observedAtEpochMillis,
            lastSeenAtEpochMillis = observedAtEpochMillis,
        )
        changed = true
    } else {
        val censusChanged = censusProvided && !nullableByteArraysEqual(existing.censusCopy(), census)
        if (existing.eventDisplayName != eventDisplayName) {
            existing.eventDisplayName = eventDisplayName
            changed = true
        }
        if (censusChanged) {
            existing.replaceCensus(census)
            changed = true
        }
        if (observedAtEpochMillis < existing.firstSeenAtEpochMillis) {
            existing.firstSeenAtEpochMillis = observedAtEpochMillis
            changed = true
        }
        if (observedAtEpochMillis > existing.lastSeenAtEpochMillis) {
            existing.lastSeenAtEpochMillis = observedAtEpochMillis
            changed = true
        }
    }

    // A hint is one of the two calls that carry a clock, so it is one of the
    // two places a due retry can be armed. The other is
    // `refreshNearbyEventDiscovery`; a host that only ever records hints
    // still retries, just at whatever cadence its beacon arrives.
    changed = armDueRegistryRetries(store, observedAtEpochMillis) || changed

    return NearbyEventDiscoveryUpdate(
        acceptedHint = true,
        changed = changed,
        snapshot = store.snapshot,
    )
}

/**
 * Lets a failed resolution be tried again once its backoff has elapsed
 * (beid#584).
 *
 * Arming clears [RegistryRecord.nextRetryAtEpochMillis] as it sets
 * [RegistryRecord.retryDue], so a deadline in the past never survives in the
 * snapshot. A host schedules its next wake-up from that snapshot value, and a
 * deadline that stayed due would be a wake-up loop for any host that cannot
 * consume the retry — one with no registry client configured, for instance.
 */
private fun armDueRegistryRetries(
    store: NearbyEventDiscoveryStore,
    nowEpochMillis: Long,
): Boolean {
    var changed = false
    store.registry.values.forEach { record ->
        if (record.attempt != null || record.retryDue) return@forEach
        if (!record.status.isRetryableFailure()) return@forEach
        val due = record.nextRetryAtEpochMillis ?: return@forEach
        if (nowEpochMillis < due) return@forEach
        record.retryDue = true
        record.nextRetryAtEpochMillis = null
        changed = true
    }
    return changed
}

private fun NearbyEventRegistryStatus.isRetryableFailure(): Boolean =
    this == NearbyEventRegistryStatus.NOT_REGISTERED ||
        this == NearbyEventRegistryStatus.LOOKUP_UNAVAILABLE

/** The wait after [failureCount] consecutive failed resolutions. */
private fun registryRetryDelayMillis(failureCount: Int): Long =
    REGISTRY_RETRY_BACKOFF_MILLIS.getOrNull(failureCount - 1)
        ?: STEADY_REGISTRY_RETRY_INTERVAL_MILLIS

/** Claims the one in-flight resolution slot for a live candidate. */
public fun beginNearbyEventRegistryResolutionFromHex(
    store: NearbyEventDiscoveryStore,
    eventCodeHashHex: String,
): NearbyEventRegistryResolutionAttempt? {
    val bytes = runCatching { eventCodeHashHex.decodeHexBytes() }.getOrNull() ?: return null
    if (bytes.size != EVENT_CODE_HASH_BYTES) return null
    val hash = EventHash(bytes)
    if (store.sources.keys.none { it.eventHash == hash }) return null
    val record = store.registry.getOrPut(hash) { RegistryRecord() }
    if (record.attempt != null) return null
    // An armed retry is the second way in (beid#584). The record keeps the
    // failed verdict it is showing until this attempt replaces it.
    if (record.status != NearbyEventRegistryStatus.UNRESOLVED && !record.retryDue) return null
    record.retryDue = false
    record.nextRetryAtEpochMillis = null
    return NearbyEventRegistryResolutionAttempt(hash).also { record.attempt = it }
}

/** True only while [attempt] is the current resolution for its live candidate. */
public fun isNearbyEventRegistryResolutionAttemptActive(
    store: NearbyEventDiscoveryStore,
    attempt: NearbyEventRegistryResolutionAttempt,
): Boolean = store.registry[attempt.eventHash]?.attempt === attempt &&
    store.sources.keys.any { it.eventHash == attempt.eventHash }

/** Delivers a native-executed lookup/verification effect back to shared state. */
public fun completeNearbyEventRegistryResolutionFromHex(
    store: NearbyEventDiscoveryStore,
    attempt: NearbyEventRegistryResolutionAttempt,
    result: NearbyEventRegistryResolutionResult,
    resolvedEventIdHex: String?,
    verifiedDefinitionJoinMode: EventJoinMode?,
    verifiedDefinitionEventIdHex: String?,
    verifiedDefinitionEventCodeHashHex: String?,
    envelopeAgreesWithRegistry: Boolean,
    /**
     * The digest of the definition this read verified, and the block it was
     * pinned to (beid#374). Both default to null so an existing caller keeps
     * compiling, and a null one simply issues no join capability later —
     * failing closed, never open.
     */
    verifiedDefinitionHashHex: String? = null,
    registryBlockHashHex: String? = null,
    /**
     * The verified definition's validity window, retained so the join issuer
     * can re-check it at issue time rather than trusting that a promotion made
     * earlier is still current.
     */
    verifiedDefinitionValidFromEpochSeconds: Long? = null,
    verifiedDefinitionValidUntilEpochSeconds: Long? = null,
): NearbyEventDiscoveryUpdate {
    val hash = attempt.eventHash
    val record = store.registry[hash]
        ?: return NearbyEventDiscoveryUpdate(false, false, store.snapshot)
    if (!isNearbyEventRegistryResolutionAttemptActive(store, attempt)) {
        return NearbyEventDiscoveryUpdate(false, false, store.snapshot)
    }
    record.attempt = null
    val bytes = hash.copyBytes()
    val signedDefinitionHash = verifiedDefinitionEventCodeHashHex
        ?.let { runCatching { it.decodeHexBytes() }.getOrNull() }
    val resolvedEventId = resolvedEventIdHex.decodeEventIdHexOrNull()
    val verifiedDefinitionEventId = verifiedDefinitionEventIdHex.decodeEventIdHexOrNull()
    val verifiedDefinitionHashMatches = result == NearbyEventRegistryResolutionResult.VERIFIED &&
        verifiedDefinitionJoinMode == EventJoinMode.OPEN &&
        resolvedEventId != null &&
        verifiedDefinitionEventId != null &&
        resolvedEventId.contentEquals(verifiedDefinitionEventId) &&
        signedDefinitionHash?.size == EVENT_CODE_HASH_BYTES &&
        signedDefinitionHash.contentEquals(bytes) &&
        eventCodeHashForOpenEventV1(verifiedDefinitionEventId).contentEquals(bytes)
    record.status = when (result) {
        NearbyEventRegistryResolutionResult.NOT_REGISTERED -> NearbyEventRegistryStatus.NOT_REGISTERED
        NearbyEventRegistryResolutionResult.VERIFIED -> if (verifiedDefinitionHashMatches) {
            NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP
        } else {
            NearbyEventRegistryStatus.LOOKUP_UNAVAILABLE
        }
        else -> NearbyEventRegistryStatus.LOOKUP_UNAVAILABLE
    }
    record.eventIdHex = resolvedEventIdHex.takeIf { verifiedDefinitionHashMatches }
    if (record.status == NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP && record.eventIdHex == null) {
        record.status = NearbyEventRegistryStatus.LOOKUP_UNAVAILABLE
    }
    // Retained only for a registration that actually stands. Anything else
    // clears them, so a later join can never read a digest left behind by a
    // resolution that was subsequently downgraded.
    val registrationStands = record.status == NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP
    record.definitionHashHex = verifiedDefinitionHashHex.takeIf { registrationStands }
    record.registryBlockHashHex = registryBlockHashHex.takeIf { registrationStands }
    record.definitionValidFromEpochSeconds = verifiedDefinitionValidFromEpochSeconds.takeIf { registrationStands }
    record.definitionValidUntilEpochSeconds = verifiedDefinitionValidUntilEpochSeconds.takeIf { registrationStands }
    // The reducer holds no clock, and this call carries none. The hash's most
    // recent observation is the closest instant it does have, and a live one
    // is guaranteed: the attempt-active check above requires a live source.
    // It runs slightly early against real time, which only ever means the
    // retry becomes eligible at the next hint rather than one after it.
    if (record.status.isRetryableFailure()) {
        record.failedResolutionCount += 1
        record.retryDue = false
        record.nextRetryAtEpochMillis = store.lastSeenAtEpochMillis(hash)
            ?.plusSaturating(registryRetryDelayMillis(record.failedResolutionCount))
    } else {
        record.failedResolutionCount = 0
        record.retryDue = false
        record.nextRetryAtEpochMillis = null
    }
    // Runs after `record.status` is final, and is a no-op unless a
    // radio-self-verified envelope for this same hash is already on record.
    store.promoteToRegistryVerified(hash, envelopeAgreesWithRegistry)
    return NearbyEventDiscoveryUpdate(false, true, store.snapshot)
}

/**
 * Swift Export boundary for native byte buffers.
 *
 * Swift Export currently emits trapping `ByteArray` constructors, so Swift
 * callers pass their exact bytes as lowercase hexadecimal text and Kotlin
 * reconstructs the arrays before entering the byte-oriented reducer above.
 */
public fun recordNearbyEventHintFromHex(
    store: NearbyEventDiscoveryStore,
    peripheralId: String,
    eventDisplayName: String,
    eventCodeHashHex: String,
    censusHex: String?,
    additionalNamesOmitted: Boolean,
    additionalEventsOmitted: Boolean,
    observedAtEpochMillis: Long,
): NearbyEventDiscoveryUpdate = recordNearbyEventHint(
    store = store,
    peripheralId = peripheralId,
    eventDisplayName = eventDisplayName,
    eventCodeHash = eventCodeHashHex.decodeHexBytes(),
    census = censusHex?.decodeHexBytes(),
    additionalNamesOmitted = additionalNamesOmitted,
    additionalEventsOmitted = additionalEventsOmitted,
    observedAtEpochMillis = observedAtEpochMillis,
)

private fun String.decodeHexBytes(): ByteArray {
    require(length % 2 == 0) { "hex value must contain complete bytes" }
    return ByteArray(length / 2) { index ->
        val high = this[index * 2].digitToIntOrNull(16)
            ?: throw IllegalArgumentException("hex value contains a non-hex character")
        val low = this[index * 2 + 1].digitToIntOrNull(16)
            ?: throw IllegalArgumentException("hex value contains a non-hex character")
        ((high shl 4) or low).toByte()
    }
}

private fun String?.decodeEventIdHexOrNull(): ByteArray? {
    val value = this ?: return null
    if (!Regex("^(0x)?[0-9a-fA-F]{64}$").matches(value)) return null
    return runCatching { value.removePrefix("0x").decodeHexBytes() }.getOrNull()
}

/** Expires sources and omission facts at the exact 300,000 ms boundary. */
public fun refreshNearbyEventDiscovery(
    store: NearbyEventDiscoveryStore,
    nowEpochMillis: Long,
): NearbyEventDiscoveryUpdate {
    if (nowEpochMillis < 0L) {
        return NearbyEventDiscoveryUpdate(false, false, store.snapshot)
    }
    var changed = expireAt(store, nowEpochMillis)
    changed = armDueRegistryRetries(store, nowEpochMillis) || changed
    return NearbyEventDiscoveryUpdate(
        acceptedHint = false,
        changed = changed,
        snapshot = store.snapshot,
    )
}

/** Clears the current discovery session, including omission and eviction facts. */
public fun resetNearbyEventDiscovery(
    store: NearbyEventDiscoveryStore,
): NearbyEventDiscoveryUpdate {
    val changed = store.sources.isNotEmpty() ||
        store.additionalNamesOmittedAtEpochMillis != null ||
        store.additionalEventsOmittedAtEpochMillis != null ||
        store.locallyEvictedSources ||
        store.unverifiedEnvelopeCount != 0
    store.sources.clear()
    store.registry.clear()
    store.receiverStates.clear()
    store.rawEnvelopeContainers.clear()
    store.unverifiedEnvelopeCount = 0
    store.additionalNamesOmittedAtEpochMillis = null
    store.additionalEventsOmittedAtEpochMillis = null
    store.locallyEvictedSources = false
    return NearbyEventDiscoveryUpdate(
        acceptedHint = false,
        changed = changed,
        snapshot = store.snapshot,
    )
}

private val sourceEvictionComparator: Comparator<MutableSourceRecord> =
    Comparator { left, right ->
        val timeComparison = left.lastSeenAtEpochMillis.compareTo(right.lastSeenAtEpochMillis)
        if (timeComparison != 0) {
            timeComparison
        } else {
            val hashComparison = left.eventHash.compareTo(right.eventHash)
            if (hashComparison != 0) hashComparison else left.peripheralId.compareTo(right.peripheralId)
        }
    }

private fun updateOmissionFacts(
    store: NearbyEventDiscoveryStore,
    additionalNamesOmitted: Boolean,
    additionalEventsOmitted: Boolean,
    observedAtEpochMillis: Long,
): Boolean {
    var changed = false
    if (additionalNamesOmitted) {
        val previous = store.additionalNamesOmittedAtEpochMillis
        if (previous == null || observedAtEpochMillis > previous) {
            store.additionalNamesOmittedAtEpochMillis = observedAtEpochMillis
            changed = true
        }
    }
    if (additionalEventsOmitted) {
        val previous = store.additionalEventsOmittedAtEpochMillis
        if (previous == null || observedAtEpochMillis > previous) {
            store.additionalEventsOmittedAtEpochMillis = observedAtEpochMillis
            changed = true
        }
    }
    return changed
}

private fun expireAt(store: NearbyEventDiscoveryStore, nowEpochMillis: Long): Boolean {
    var changed = false
    val expiredKeys = store.sources
        .filterValues { source -> hasExpired(source.lastSeenAtEpochMillis, nowEpochMillis) }
        .keys
    if (expiredKeys.isNotEmpty()) {
        expiredKeys.forEach(store.sources::remove)
        val liveHashes = store.sources.keys.map { it.eventHash }.toSet()
        store.registry.keys.retainAll(liveHashes)
        store.receiverStates.keys.retainAll(liveHashes)
        store.rawEnvelopeContainers.keys.retainAll(liveHashes)
        changed = true
    }

    val namesObservedAt = store.additionalNamesOmittedAtEpochMillis
    if (namesObservedAt != null && hasExpired(namesObservedAt, nowEpochMillis)) {
        store.additionalNamesOmittedAtEpochMillis = null
        changed = true
    }
    val eventsObservedAt = store.additionalEventsOmittedAtEpochMillis
    if (eventsObservedAt != null && hasExpired(eventsObservedAt, nowEpochMillis)) {
        store.additionalEventsOmittedAtEpochMillis = null
        changed = true
    }
    return changed
}

private fun hasExpired(observedAtEpochMillis: Long, nowEpochMillis: Long): Boolean =
    nowEpochMillis >= observedAtEpochMillis &&
        nowEpochMillis - observedAtEpochMillis >= DISCOVERY_TTL_MILLIS

private fun NearbyEventDiscoveryStore.buildSnapshot(): NearbyEventCandidates {
    val candidates = sources.values
        .groupBy { source -> source.eventHash }
        .entries
        .sortedBy { entry -> entry.key }
        .map { (eventHash, records) ->
            val orderedSources = records
                .sortedBy { source -> source.peripheralId }
                .map { source ->
                    NearbyEventSourceObservation(
                        peripheralId = source.peripheralId,
                        eventDisplayName = source.eventDisplayName,
                        census = source.censusCopy(),
                        firstSeenAtEpochMillis = source.firstSeenAtEpochMillis,
                        lastSeenAtEpochMillis = source.lastSeenAtEpochMillis,
                    )
                }
            NearbyEventCandidate(
                eventCodeHash = eventHash.copyBytes(),
                firstSeenAtEpochMillis = records.minOf { source -> source.firstSeenAtEpochMillis },
                lastSeenAtEpochMillis = records.maxOf { source -> source.lastSeenAtEpochMillis },
                sources = orderedSources,
                displayNames = records.map { source -> source.eventDisplayName }.distinct().sorted(),
                registryStatus = registry[eventHash]?.status ?: NearbyEventRegistryStatus.UNRESOLVED,
                resolvedEventIdHex = registry[eventHash]?.eventIdHex,
                receiverState = receiverStates[eventHash] ?: NearbyEventReceiverState.UNVERIFIED,
                verifiedDefinitionHashHex = registry[eventHash]?.definitionHashHex,
                registryBlockHashHex = registry[eventHash]?.registryBlockHashHex,
                definitionValidFromEpochSeconds = registry[eventHash]?.definitionValidFromEpochSeconds,
                definitionValidUntilEpochSeconds = registry[eventHash]?.definitionValidUntilEpochSeconds,
                registryResolutionFailureCount = registry[eventHash]?.failedResolutionCount ?: 0,
                registryRetryAtEpochMillis = registry[eventHash]?.nextRetryAtEpochMillis,
                rawEnvelopeContainer = rawEnvelopeContainers[eventHash],
            )
        }

    val expiryTimes = buildList {
        sources.values.forEach { source -> add(expiryAt(source.lastSeenAtEpochMillis)) }
        additionalNamesOmittedAtEpochMillis?.let { observedAt -> add(expiryAt(observedAt)) }
        additionalEventsOmittedAtEpochMillis?.let { observedAt -> add(expiryAt(observedAt)) }
    }
    return NearbyEventCandidates(
        candidates = candidates,
        additionalNamesOmitted = additionalNamesOmittedAtEpochMillis != null,
        additionalEventsOmitted = additionalEventsOmittedAtEpochMillis != null,
        hasLocallyEvictedSources = locallyEvictedSources,
        nextExpiryAtEpochMillis = expiryTimes.minOrNull(),
        nextRegistryRetryAtEpochMillis = registry.values.mapNotNull { it.nextRetryAtEpochMillis }.minOrNull(),
        unverifiedEnvelopeCount = unverifiedEnvelopeCount,
    )
}

private fun NearbyEventDiscoveryStore.lastSeenAtEpochMillis(hash: EventHash): Long? =
    sources.values
        .filter { source -> source.eventHash == hash }
        .maxOfOrNull { source -> source.lastSeenAtEpochMillis }

private fun Long.plusSaturating(other: Long): Long =
    if (this > Long.MAX_VALUE - other) Long.MAX_VALUE else this + other

private fun expiryAt(observedAtEpochMillis: Long): Long =
    if (observedAtEpochMillis > Long.MAX_VALUE - DISCOVERY_TTL_MILLIS) {
        Long.MAX_VALUE
    } else {
        observedAtEpochMillis + DISCOVERY_TTL_MILLIS
    }

private fun nullableByteArraysEqual(left: ByteArray?, right: ByteArray?): Boolean = when {
    left == null -> right == null
    right == null -> false
    else -> left.contentEquals(right)
}

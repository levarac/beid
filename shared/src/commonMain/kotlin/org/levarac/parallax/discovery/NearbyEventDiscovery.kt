package org.levarac.parallax.discovery

import org.levarac.parallax.registry.EventJoinMode
import org.levarac.parallax.registry.eventCodeHashForOpenEventV1

private const val DISCOVERY_TTL_MILLIS: Long = 300_000L
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
 *   gate. Holding it to [REGISTRY_VERIFIED] would make it permanently
 *   unjoinable and regress the shipped v1 join path.
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
     * Held apart from [registry] on purpose. `recordNearbyEventHint` replaces a
     * whole [RegistryRecord] to retry a failed lookup, and a receiver state
     * stored inside that record would be silently downgraded by an ordinary
     * re-observation after a flaky registry read.
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
 */
public fun recordNearbyEventRadioSelfVerifiedEnvelope(
    store: NearbyEventDiscoveryStore,
    peripheralId: String,
    eventDisplayName: String,
    eventCodeHash: ByteArray,
    rawContainer: ByteArray,
    additionalNamesOmitted: Boolean,
    additionalEventsOmitted: Boolean,
    observedAtEpochMillis: Long,
): NearbyEventDiscoveryUpdate {
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
    // The newest container for a hash replaces the one held. Spec 134 elects
    // by hop among what a device can currently observe, so the freshest bytes
    // are the ones a relay decision should be made from; an older copy of the
    // same event is not more authoritative for being older.
    val containerChanged = !store.rawEnvelopeContainers[hash].contentEqualsOrNull(rawContainer)
    if (containerChanged) store.rawEnvelopeContainers[hash] = rawContainer.copyOf()
    if (!raised && !containerChanged) return update
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
 */
public fun recordNearbyEventUnverifiedEnvelope(
    store: NearbyEventDiscoveryStore,
): NearbyEventDiscoveryUpdate {
    store.unverifiedEnvelopeCount += 1
    return NearbyEventDiscoveryUpdate(
        acceptedHint = false,
        changed = true,
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
    additionalNamesOmitted: Boolean,
    additionalEventsOmitted: Boolean,
    observedAtEpochMillis: Long,
): NearbyEventDiscoveryUpdate = recordNearbyEventRadioSelfVerifiedEnvelope(
    store = store,
    peripheralId = peripheralId,
    eventDisplayName = eventDisplayName,
    eventCodeHash = runCatching { eventCodeHashHex.decodeHexBytes() }.getOrElse { ByteArray(0) },
    rawContainer = runCatching { rawContainerHex.decodeHexBytes() }.getOrElse { ByteArray(0) },
    additionalNamesOmitted = additionalNamesOmitted,
    additionalEventsOmitted = additionalEventsOmitted,
    observedAtEpochMillis = observedAtEpochMillis,
)

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
        if (store.registry[eventHash]?.status == NearbyEventRegistryStatus.LOOKUP_UNAVAILABLE) {
            store.registry[eventHash] = RegistryRecord()
            changed = true
        }
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

    return NearbyEventDiscoveryUpdate(
        acceptedHint = true,
        changed = changed,
        snapshot = store.snapshot,
    )
}

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
    if (record.attempt != null || record.status != NearbyEventRegistryStatus.UNRESOLVED) return null
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
    val changed = expireAt(store, nowEpochMillis)
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
        unverifiedEnvelopeCount = unverifiedEnvelopeCount,
    )
}

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

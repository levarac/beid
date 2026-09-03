package org.levarac.parallax.discovery

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
 * and its signed EventDefinition hash exactly matched the B005 hash.
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
) {
    private val eventCodeHashBytes: ByteArray = eventCodeHash.copyOf()

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

    public val snapshot: NearbyEventCandidates
        get() = buildSnapshot()
}

internal data class RegistryRecord(
    var status: NearbyEventRegistryStatus = NearbyEventRegistryStatus.UNRESOLVED,
    var eventIdHex: String? = null,
    var inFlight: Boolean = false,
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
        val censusChanged = !nullableByteArraysEqual(existing.censusCopy(), census)
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
): Boolean {
    val bytes = runCatching { eventCodeHashHex.decodeHexBytes() }.getOrNull() ?: return false
    if (bytes.size != EVENT_CODE_HASH_BYTES) return false
    val hash = EventHash(bytes)
    if (store.sources.keys.none { it.eventHash == hash }) return false
    val record = store.registry.getOrPut(hash) { RegistryRecord() }
    if (record.inFlight || record.status != NearbyEventRegistryStatus.UNRESOLVED) return false
    record.inFlight = true
    return true
}

/** Delivers a native-executed lookup/verification effect back to shared state. */
public fun completeNearbyEventRegistryResolutionFromHex(
    store: NearbyEventDiscoveryStore,
    eventCodeHashHex: String,
    result: NearbyEventRegistryResolutionResult,
    resolvedEventIdHex: String?,
    verifiedDefinitionEventCodeHashHex: String?,
): NearbyEventDiscoveryUpdate {
    val bytes = runCatching { eventCodeHashHex.decodeHexBytes() }.getOrNull()
        ?: return NearbyEventDiscoveryUpdate(false, false, store.snapshot)
    val hash = EventHash(bytes)
    val record = store.registry[hash]
    if (bytes.size != EVENT_CODE_HASH_BYTES || record?.inFlight != true ||
        store.sources.keys.none { it.eventHash == hash }) {
        return NearbyEventDiscoveryUpdate(false, false, store.snapshot)
    }
    record.inFlight = false
    val verifiedDefinitionHashMatches = verifiedDefinitionEventCodeHashHex
        ?.let { runCatching { it.decodeHexBytes() }.getOrNull() }
        ?.let { it.size == EVENT_CODE_HASH_BYTES && it.contentEquals(bytes) }
        ?: false
    record.status = when (result) {
        NearbyEventRegistryResolutionResult.NOT_REGISTERED -> NearbyEventRegistryStatus.NOT_REGISTERED
        NearbyEventRegistryResolutionResult.VERIFIED -> if (verifiedDefinitionHashMatches) {
            NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP
        } else {
            NearbyEventRegistryStatus.LOOKUP_UNAVAILABLE
        }
        else -> NearbyEventRegistryStatus.LOOKUP_UNAVAILABLE
    }
    record.eventIdHex = resolvedEventIdHex.takeIf {
        result == NearbyEventRegistryResolutionResult.VERIFIED && verifiedDefinitionHashMatches &&
            it != null && Regex("^(0x)?[0-9a-fA-F]{64}$").matches(it)
    }
    if (record.status == NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP && record.eventIdHex == null) {
        record.status = NearbyEventRegistryStatus.LOOKUP_UNAVAILABLE
    }
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
        store.locallyEvictedSources
    store.sources.clear()
    store.registry.clear()
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

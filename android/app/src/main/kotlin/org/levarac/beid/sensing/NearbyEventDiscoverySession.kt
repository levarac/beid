package org.levarac.beid.sensing

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.levarac.barnard.BarnardEventDefinitionV1
import org.levarac.parallax.discovery.NearbyEventCandidates
import org.levarac.parallax.discovery.NearbyEventReceiverState
import org.levarac.parallax.discovery.NearbyEventRegistryStatus
import org.levarac.parallax.discovery.createNearbyEventDiscoveryStore
import org.levarac.parallax.discovery.applyNearbyEventRegistryAgreementFromHex
import org.levarac.parallax.discovery.recordNearbyEventHint
import org.levarac.parallax.discovery.recordNearbyEventRadioSelfVerifiedEnvelope
import org.levarac.parallax.discovery.refreshNearbyEventDiscovery
import org.levarac.parallax.discovery.resetNearbyEventDiscovery
import org.levarac.parallax.discovery.beginNearbyEventRegistryResolutionFromHex
import org.levarac.parallax.discovery.completeNearbyEventRegistryResolutionFromHex
import org.levarac.parallax.discovery.isNearbyEventRegistryResolutionAttemptActive
import org.levarac.parallax.discovery.NearbyEventRegistryResolutionResult
import org.levarac.parallax.registry.EventJoinMode
import org.levarac.parallax.registry.RegistryClient
import org.levarac.parallax.registry.safeRegistryReadPin

internal fun interface NearbyEventRegistryRequest {
    fun cancel()
}

internal data class NearbyEventIdLookup(
    val isSuccess: Boolean,
    val eventIdHex: String?,
    val errorCode: String?,
)

internal data class NearbyEventDefinitionVerification(
    val isSuccess: Boolean,
    val joinMode: EventJoinMode?,
    val eventIdHex: String?,
    val eventCodeHashHex: String?,
    val validFromEpochSeconds: Long?,
    val validUntilEpochSeconds: Long?,
    val keySetDigestHex: String? = null,
)

/** Native effect seam; the shared reducer below remains the trust authority. */
internal interface NearbyEventRegistry {
    fun resolveEventIdByCodeHash(
        hashHex: String,
        completion: (NearbyEventIdLookup) -> Unit,
    ): NearbyEventRegistryRequest

    fun resolveEventDefinition(
        eventIdHex: String,
        useTimeEpochSeconds: Long,
        completion: (NearbyEventDefinitionVerification) -> Unit,
    ): NearbyEventRegistryRequest
}

internal class RegistryClientNearbyEventRegistry(
    private val client: RegistryClient,
) : NearbyEventRegistry {
    override fun resolveEventIdByCodeHash(
        hashHex: String,
        completion: (NearbyEventIdLookup) -> Unit,
    ): NearbyEventRegistryRequest {
        val request = client.resolveEventIdByCodeHash(hashHex) {
            completion(NearbyEventIdLookup(it.isSuccess, it.eventIdHex, it.errorCode))
        }
        return NearbyEventRegistryRequest(request::cancel)
    }

    override fun resolveEventDefinition(
        eventIdHex: String,
        useTimeEpochSeconds: Long,
        completion: (NearbyEventDefinitionVerification) -> Unit,
    ): NearbyEventRegistryRequest {
        val request = client.resolveEventDefinition(
            eventIdHex,
            safeRegistryReadPin(),
            useTimeEpochSeconds,
        ) {
            completion(
                NearbyEventDefinitionVerification(
                    isSuccess = it.isSuccess,
                    joinMode = it.context?.joinMode,
                    eventIdHex = it.context?.eventIdHex,
                    eventCodeHashHex = it.context?.eventCodeHashHex,
                    validFromEpochSeconds = it.context?.validFrom?.value,
                    validUntilEpochSeconds = it.context?.validUntil?.value,
                    keySetDigestHex = it.context?.definition?.keySetDigestHex,
                ),
            )
        }
        return NearbyEventRegistryRequest(request::cancel)
    }
}

/**
 * Android lifecycle owner for the shared, pure nearby-event discovery store.
 * All mutations are confined to the coordinator's event/callback context.
 */
internal class NearbyEventDiscoverySession(
    private val nowEpochMillis: () -> Long,
    private val coroutineScope: CoroutineScope,
    private val registry: NearbyEventRegistry? = null,
) {
    private val store = createNearbyEventDiscoveryStore()
    private val _candidates = MutableStateFlow(store.snapshot)
    private val _cards = MutableStateFlow<List<NearbyEventCard>>(emptyList())
    private val verifiedMetadataByHash = mutableMapOf<String, VerifiedNearbyEventMetadata>()

    /**
     * Barnard's `registryAgreement` for the radio-self-verified envelope last
     * seen for a hash, held as a closure because `BarnardB005VerifiedEnvelope`
     * has no public constructor and so cannot be carried across a test seam.
     * The host never re-implements the comparison; it only decides *when* to
     * ask barnard for it.
     */
    private val envelopeAgreementByHash = mutableMapOf<String, (BarnardEventDefinitionV1) -> Boolean>()

    /**
     * The definition this host's own authenticated registry read returned,
     * kept so an envelope arriving *after* a hash's single registry resolution
     * completed still has something to be compared against.
     */
    private val verifiedDefinitionByHash = mutableMapOf<String, BarnardEventDefinitionV1>()
    private var expiryJob: Job? = null
    private var disposed = false
    private var callbackGeneration = 0L
    private val registryRequests = mutableSetOf<NearbyEventRegistryRequest>()

    val candidates: StateFlow<NearbyEventCandidates> = _candidates.asStateFlow()
    val cards: StateFlow<List<NearbyEventCard>> = _cards.asStateFlow()

    fun recordHint(
        peripheralId: String,
        eventDisplayName: String,
        eventCodeHash: ByteArray,
        census: ByteArray?,
        additionalNamesOmitted: Boolean,
        additionalEventsOmitted: Boolean,
    ) {
        if (disposed) return
        val update = recordNearbyEventHint(
            store = store,
            peripheralId = peripheralId,
            eventDisplayName = eventDisplayName,
            eventCodeHash = eventCodeHash,
            census = census,
            additionalNamesOmitted = additionalNamesOmitted,
            additionalEventsOmitted = additionalEventsOmitted,
            observedAtEpochMillis = nowEpochMillis(),
        )
        publishAndSchedule(update.snapshot)
        resolveUnresolvedCandidates(update.snapshot)
    }

    /**
     * Records a B005 v2 envelope barnard reported as `RADIO_SELF_VERIFIED`.
     *
     * [registryAgreement] is barnard's own pure comparison bound to this
     * envelope. It is invoked only against a definition this host read from
     * the registry itself, never against anything off the radio.
     *
     * An `UNVERIFIED` receipt must not reach here: barnard's `verify` returns
     * nothing for both a malformed container and a bad signature, so such a
     * receipt has no event-code hash and describes no candidate.
     */
    fun recordRadioSelfVerifiedEnvelope(
        peripheralId: String,
        eventDisplayName: String,
        eventCodeHash: ByteArray,
        registryAgreement: (BarnardEventDefinitionV1) -> Boolean,
    ) {
        if (disposed) return
        val update = recordNearbyEventRadioSelfVerifiedEnvelope(
            store = store,
            peripheralId = peripheralId,
            eventDisplayName = eventDisplayName,
            eventCodeHash = eventCodeHash,
            additionalNamesOmitted = false,
            additionalEventsOmitted = false,
            observedAtEpochMillis = nowEpochMillis(),
        )
        if (!update.acceptedHint) return
        val hash = eventCodeHash.joinToString("") { "%02x".format(it.toInt() and 0xff) }
        envelopeAgreementByHash[hash] = registryAgreement
        // The registry resolution for a hash completes exactly once, so an
        // envelope that lands after it has no completion callback left to ride
        // on and must promote through the standalone agreement entry.
        val promoted = verifiedDefinitionByHash[hash]?.let { definition ->
            applyNearbyEventRegistryAgreementFromHex(store, hash, registryAgreement(definition)).snapshot
        }
        publishAndSchedule(promoted ?: update.snapshot)
        resolveUnresolvedCandidates(update.snapshot)
    }

    fun reset() {
        callbackGeneration += 1
        registryRequests.forEach { it.cancel() }
        registryRequests.clear()
        expiryJob?.cancel()
        expiryJob = null
        _candidates.value = resetNearbyEventDiscovery(store).snapshot
        verifiedMetadataByHash.clear()
        envelopeAgreementByHash.clear()
        verifiedDefinitionByHash.clear()
        _cards.value = emptyList()
    }

    private fun resolveUnresolvedCandidates(snapshot: NearbyEventCandidates) {
        val client = registry ?: return
        repeat(snapshot.candidateCount) { index ->
            val candidate = snapshot.candidateAt(index) ?: return@repeat
            val hash = candidate.eventCodeHash.joinToString("") { "%02x".format(it.toInt() and 0xff) }
            val attempt = beginNearbyEventRegistryResolutionFromHex(store, hash) ?: return@repeat
            val generation = callbackGeneration
            // The whole body runs on coroutineScope's dispatcher (Main.immediate,
            // set by the caller), matching the iOS adapter's `Task { @MainActor }`
            // wrapping. This confines every registryRequests mutation to one
            // thread (resolveEventIdByCodeHash/resolveEventDefinition complete on
            // a background dispatcher per RegistryClient's own scope) and, since
            // launch{} never runs synchronously inline, guarantees `lookup`/
            // `verification` are assigned before this block can read them even
            // on a completion path that calls back before the outer function
            // returns.
            lateinit var lookup: NearbyEventRegistryRequest
            lookup = client.resolveEventIdByCodeHash(hash) { resolution ->
                coroutineScope.launch {
                    registryRequests.remove(lookup)
                    if (disposed || generation != callbackGeneration ||
                        !isNearbyEventRegistryResolutionAttemptActive(store, attempt)) return@launch
                    val eventId = resolution.eventIdHex
                    if (!resolution.isSuccess || eventId == null) {
                        val result = if (resolution.errorCode == "event_code_lookup_not_found")
                            NearbyEventRegistryResolutionResult.NOT_REGISTERED
                        else NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE
                        publishAndSchedule(
                            completeNearbyEventRegistryResolutionFromHex(
                                store = store,
                                attempt = attempt,
                                result = result,
                                resolvedEventIdHex = null,
                                verifiedDefinitionJoinMode = null,
                                verifiedDefinitionEventIdHex = null,
                                verifiedDefinitionEventCodeHashHex = null,
                                envelopeAgreesWithRegistry = false,
                            ).snapshot,
                        )
                        return@launch
                    }
                    lateinit var verification: NearbyEventRegistryRequest
                    verification = client.resolveEventDefinition(eventId, nowEpochMillis() / 1000L) { verified ->
                        coroutineScope.launch {
                            registryRequests.remove(verification)
                            if (disposed || generation != callbackGeneration ||
                                !isNearbyEventRegistryResolutionAttemptActive(store, attempt)) return@launch
                            val result = if (verified.isSuccess) NearbyEventRegistryResolutionResult.VERIFIED
                            else NearbyEventRegistryResolutionResult.VERIFICATION_UNAVAILABLE
                            val definition = verified.toBarnardDefinition()
                            if (definition != null && result == NearbyEventRegistryResolutionResult.VERIFIED) {
                                verifiedDefinitionByHash[hash] = definition
                            } else {
                                verifiedDefinitionByHash.remove(hash)
                            }
                            // Barnard owns the comparison. This decides only that
                            // it is asked with a definition this host read itself.
                            val agrees = definition != null &&
                                envelopeAgreementByHash[hash]?.invoke(definition) == true
                            val update = completeNearbyEventRegistryResolutionFromHex(
                                    store = store,
                                    attempt = attempt,
                                    result = result,
                                    resolvedEventIdHex = eventId,
                                    verifiedDefinitionJoinMode = verified.joinMode,
                                    verifiedDefinitionEventIdHex = verified.eventIdHex,
                                    verifiedDefinitionEventCodeHashHex = verified.eventCodeHashHex,
                                    envelopeAgreesWithRegistry = agrees,
                                )
                            updateVerifiedCard(
                                hash,
                                eventId,
                                verified.validFromEpochSeconds,
                                verified.validUntilEpochSeconds,
                                update.snapshot,
                            )
                            publishAndSchedule(update.snapshot)
                        }
                    }
                    registryRequests += verification
                }
            }
            registryRequests += lookup
        }
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        reset()
    }

    private fun publishAndSchedule(snapshot: NearbyEventCandidates) {
        val now = nowEpochMillis()
        val nowEpochSeconds = now / 1_000L
        verifiedMetadataByHash.entries.removeAll { it.value.validUntilEpochSeconds < nowEpochSeconds }
        _candidates.value = snapshot
        val liveHashes = buildSet {
            repeat(snapshot.candidateCount) { index -> snapshot.candidateAt(index)?.let { add(it.eventCodeHashHex) } }
        }
        verifiedMetadataByHash.keys.retainAll(liveHashes)
        envelopeAgreementByHash.keys.retainAll(liveHashes)
        verifiedDefinitionByHash.keys.retainAll(liveHashes)
        _cards.value = buildList {
            repeat(snapshot.candidateCount) { index ->
                snapshot.candidateAt(index)?.let { candidate ->
                    val verified = verifiedMetadataByHash[candidate.eventCodeHashHex]
                    add(
                        NearbyEventCard(
                            beaconDisplayName = candidate.displayNameAt(0),
                            eventIdHex = verified?.eventIdHex,
                            validFromEpochSeconds = verified?.validFromEpochSeconds,
                            validUntilEpochSeconds = verified?.validUntilEpochSeconds,
                            eventCodeHashHex = candidate.eventCodeHashHex,
                        ),
                    )
                }
            }
        }
        expiryJob?.cancel()
        expiryJob = null

        val definitionExpiryAt = verifiedMetadataByHash.values.minOfOrNull {
            firstEpochMillisAfter(it.validUntilEpochSeconds)
        }
        val nextExpiryAt = listOfNotNull(snapshot.nextExpiryAtEpochMillis, definitionExpiryAt).minOrNull() ?: return
        val delayMillis = if (nextExpiryAt <= now) 0L else nextExpiryAt - now
        expiryJob = coroutineScope.launch {
            delay(delayMillis)
            expiryJob = null
            if (disposed) return@launch
            val update = refreshNearbyEventDiscovery(store, nowEpochMillis())
            publishAndSchedule(update.snapshot)
        }
    }

    /**
     * The shared reducer remains the sole trust predicate. Native code only
     * carries period fields from the already verified context after that
     * reducer exposes REGISTERED_VIA_OPERATOR_LOOKUP for the same candidate.
     */
    private fun updateVerifiedCard(
        hash: String,
        eventIdHex: String,
        validFrom: Long?,
        validUntil: Long?,
        snapshot: NearbyEventCandidates,
    ) {
        val candidate = (0 until snapshot.candidateCount)
            .mapNotNull(snapshot::candidateAt)
            .firstOrNull { it.eventCodeHashHex == hash }
        // A candidate that carried a B005 v2 envelope must reach
        // REGISTRY_VERIFIED before it becomes joinable; only an eventIdHex on
        // the card makes it so. A candidate assembled from v1 hints alone can
        // never reach that tier, so it keeps the existing registry-status gate
        // and the v1 join path is unchanged.
        val receiverStateAllowsJoin = candidate?.receiverState != NearbyEventReceiverState.RADIO_SELF_VERIFIED
        if (receiverStateAllowsJoin &&
            candidate?.registryStatus == NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP &&
            candidate.resolvedEventIdHex == eventIdHex && validFrom != null && validUntil != null
        ) {
            verifiedMetadataByHash[hash] = VerifiedNearbyEventMetadata(eventIdHex, validFrom, validUntil)
        } else {
            verifiedMetadataByHash.remove(hash)
        }
    }

    /**
     * Builds barnard's `BarnardEventDefinitionV1` from a verified registry
     * read. `joinMode` is the wire value the Event Definition CBOR carries
     * (`0` open, `1` gated), not an enum ordinal that happens to match. Any
     * missing or malformed field yields null, which can only ever withhold
     * promotion.
     */
    private fun NearbyEventDefinitionVerification.toBarnardDefinition(): BarnardEventDefinitionV1? {
        val eventId = eventIdHex.hexBytesOrNull(32) ?: return null
        val keySetDigest = keySetDigestHex.hexBytesOrNull(32) ?: return null
        val codeHash = eventCodeHashHex.hexBytesOrNull(8) ?: return null
        val mode = when (joinMode) {
            EventJoinMode.OPEN -> 0
            EventJoinMode.GATED -> 1
            null -> return null
        }
        return BarnardEventDefinitionV1(
            eventId = eventId,
            keySetDigest = keySetDigest,
            joinMode = mode,
            eventCodeHash = codeHash,
            validFromUnixSeconds = validFromEpochSeconds ?: return null,
            validUntilUnixSeconds = validUntilEpochSeconds ?: return null,
        )
    }

    private fun String?.hexBytesOrNull(expectedBytes: Int): ByteArray? {
        val value = this?.removePrefix("0x") ?: return null
        if (value.length != expectedBytes * 2) return null
        return ByteArray(expectedBytes) { index ->
            val high = value[index * 2].digitToIntOrNull(16) ?: return null
            val low = value[index * 2 + 1].digitToIntOrNull(16) ?: return null
            ((high shl 4) or low).toByte()
        }
    }

    private data class VerifiedNearbyEventMetadata(
        val eventIdHex: String,
        val validFromEpochSeconds: Long,
        val validUntilEpochSeconds: Long,
    )

    private fun firstEpochMillisAfter(epochSecond: Long): Long {
        val latestConvertibleSecond = Long.MAX_VALUE / 1_000L
        return if (epochSecond >= latestConvertibleSecond) Long.MAX_VALUE
        else (epochSecond + 1L) * 1_000L
    }
}

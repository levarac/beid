package org.levarac.beid.sensing

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.levarac.barnard.BarnardEventDefinitionV1
import org.levarac.beid.BuildConfig
import org.levarac.parallax.discovery.NearbyEventCandidates
import org.levarac.parallax.discovery.NearbyEventJoinEligibility
import org.levarac.parallax.discovery.NearbyEventRegistryStatus
import org.levarac.parallax.discovery.createNearbyEventDiscoveryStore
import org.levarac.parallax.discovery.nearbyCandidateJoinEligibility
import org.levarac.parallax.discovery.recordNearbyEventHint
import org.levarac.parallax.discovery.recordNearbyEventRadioSelfVerifiedEnvelope
import org.levarac.parallax.discovery.recordNearbyEventUnverifiedEnvelope
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
    /**
     * The verified Event Definition's digest and the pinned registry block it
     * was read at (beid#374). Discovery itself does not read either one; they
     * are retained on the candidate so a later join can prove it is joining
     * the same definition that promoted it.
     */
    val definitionHashHex: String? = null,
    val blockHashHex: String? = null,
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
                    definitionHashHex = it.definitionHashHex,
                    blockHashHex = it.blockHashHex,
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
    /**
     * Where this session's diagnostic lines go (beid#584, feeding beid#583).
     *
     * Injected rather than called directly so a test can assert the lines
     * themselves. Every call site is gated on `BuildConfig.DEBUG`, matching
     * `WindowObservationAccumulator`. Diagnostics never log an event-code
     * hash, RPID or raw envelope; only the first eight hex characters of a
     * verified Event ID may appear. The field capture behind beid#584 filtered logcat to the
     * app's own pid and found sixty-nine lines, every one of them Android's
     * `BluetoothGatt` and not one of them the app's, which is why a stuck
     * verification could not be diagnosed while the rig was running.
     */
    private val log: (String) -> Unit = ::logRuntimeDiagnostic,
) {
    private val store = createNearbyEventDiscoveryStore()
    private val _candidates = MutableStateFlow(store.snapshot)
    private val _cards = MutableStateFlow<List<NearbyEventCard>>(emptyList())

    /**
     * A cache, never a gate (beid#454). The card projection reads
     * `eventIdHex` / validity window from the shared candidate directly, the
     * same source iOS's `SensingView` already reads, so joinability has
     * exactly one shared answer on both platforms. This map exists only for
     * [publishAndSchedule]'s expiry-scheduling scan below; it is pruned on
     * the same live-hash and TTL rules as the other native per-hash caches,
     * so it can go briefly missing for a candidate that source eviction
     * (`NearbyEventDiscovery.kt`'s `MAX_LIVE_SOURCE_COUNT`) dropped and
     * re-admitted, while the candidate's own registry evidence survives that
     * eviction untouched. A card must never depend on this map being present
     * -- that dependency is exactly what made Android and iOS disagree.
     */
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
    private val verifiedEventIdByHash = mutableMapOf<String, String>()
    private var expiryJob: Job? = null
    private var disposed = false
    private var callbackGeneration = 0L
    private val registryRequests = mutableSetOf<NearbyEventRegistryRequest>()

    val candidates: StateFlow<NearbyEventCandidates> = _candidates.asStateFlow()
    val cards: StateFlow<List<NearbyEventCard>> = _cards.asStateFlow()

    /**
     * The verified definitions behind the current candidates, copied.
     *
     * barnard's relay verifier runs on the thread a GATT read arrived on, so
     * it must never read this session's mutable maps. Copying is what makes
     * the hand-off safe, and the map is bounded by the live candidate set.
     */
    fun verifiedDefinitionsByHash(): Map<String, BarnardEventDefinitionV1> =
        verifiedDefinitionByHash.toMap()

    fun recordHint(
        peripheralId: String,
        eventDisplayName: String,
        eventCodeHash: ByteArray,
        census: ByteArray?,
        additionalNamesOmitted: Boolean,
        additionalEventsOmitted: Boolean,
    ) {
        if (disposed) return
        emitJoinStageDiagnostic(log, eventIdHex = null, stage = "detection", outcome = "detected")
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
        rawContainer: ByteArray,
        verifiedEventIdHex: String? = null,
        registryAgreement: (BarnardEventDefinitionV1) -> Boolean,
    ) {
        if (disposed) return
        val hash = eventCodeHash.joinToString("") { "%02x".format(it.toInt() and 0xff) }
        // Asked before recording, because the reducer needs this envelope's
        // own verdict to decide whether it may replace the container retained
        // for a hash that is already REGISTRY_VERIFIED.
        val agrees = verifiedDefinitionByHash[hash]?.let(registryAgreement) == true
        val update = recordNearbyEventRadioSelfVerifiedEnvelope(
            store = store,
            peripheralId = peripheralId,
            eventDisplayName = eventDisplayName,
            eventCodeHash = eventCodeHash,
            rawContainer = rawContainer,
            agreesWithRegistry = agrees,
            additionalNamesOmitted = false,
            additionalEventsOmitted = false,
            observedAtEpochMillis = nowEpochMillis(),
        )
        if (!update.acceptedHint) return
        emitJoinStageDiagnostic(
            log,
            eventIdHex = verifiedEventIdHex,
            stage = "envelope_verification",
            outcome = "success",
        )
        if (verifiedEventIdHex != null) {
            verifiedEventIdByHash[hash] = verifiedEventIdHex
        }
        envelopeAgreementByHash[hash] = registryAgreement
        // No second call for the late-arrival order: the record above already
        // acted on `agrees`, under the same guard the standalone agreement
        // entry uses.
        publishAndSchedule(update.snapshot)
        resolveUnresolvedCandidates(update.snapshot)
    }

    /**
     * Records that barnard could not verify a container this session saw.
     *
     * There is nothing else to record -- an unverified receipt has no parsed
     * identity at all -- so this tally is the only trace the drop leaves, and
     * it is what makes the drop observable rather than silent.
     */
    fun recordUnverifiedEnvelope() {
        if (disposed) return
        emitJoinStageDiagnostic(
            log,
            eventIdHex = null,
            stage = "envelope_verification",
            outcome = "rejected_unverified",
        )
        // Publishes the candidates flow so the tally is observable, and stops
        // there. Deliberately not publishAndSchedule: no candidate, source or
        // expiry time moved, so rebuilding the card list and re-arming the
        // expiry wake-up would let a peer transmitting garbage drive both on
        // every received packet.
        _candidates.value = recordNearbyEventUnverifiedEnvelope(store).snapshot
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
        verifiedEventIdByHash.clear()
        _cards.value = emptyList()
    }

    private fun resolveUnresolvedCandidates(snapshot: NearbyEventCandidates) {
        val client = registry ?: return
        repeat(snapshot.candidateCount) { index ->
            val candidate = snapshot.candidateAt(index) ?: return@repeat
            val hash = candidate.eventCodeHash.joinToString("") { "%02x".format(it.toInt() and 0xff) }
            val attemptNumber = candidate.registryResolutionFailureCount + 1
            val attempt = beginNearbyEventRegistryResolutionFromHex(store, hash) ?: return@repeat
            emitJoinStageDiagnostic(
                log,
                eventIdHex = verifiedEventIdByHash[hash],
                stage = "registry_resolution",
                outcome = "started",
                attempt = attemptNumber,
            )
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
            val directEventId = verifiedEventIdByHash[hash]
            val handleLookup: (NearbyEventIdLookup) -> Unit = { resolution ->
                coroutineScope.launch {
                    registryRequests.remove(lookup)
                    if (disposed || generation != callbackGeneration ||
                        !isNearbyEventRegistryResolutionAttemptActive(store, attempt)) return@launch
                    val eventId = resolution.eventIdHex
                    if (!resolution.isSuccess || eventId == null) {
                        val result = if (resolution.errorCode == "event_code_lookup_not_found")
                            NearbyEventRegistryResolutionResult.NOT_REGISTERED
                        else NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE
                        val failure = completeNearbyEventRegistryResolutionFromHex(
                            store = store,
                            attempt = attempt,
                            result = result,
                            resolvedEventIdHex = null,
                            verifiedDefinitionJoinMode = null,
                            verifiedDefinitionEventIdHex = null,
                            verifiedDefinitionEventCodeHashHex = null,
                            envelopeAgreesWithRegistry = false,
                        )
                        // The reducer scheduled a wait, not a deadline; this
                        // refresh is the clock reading that anchors it, and it
                        // has to happen before the log line and the wake-up
                        // scheduling both read it back (PR 595 review, P1).
                        val armed = refreshNearbyEventDiscovery(store, nowEpochMillis())
                        logResolutionOutcome(hash, null, result, attemptNumber, armed.snapshot)
                        publishAndSchedule(armed.snapshot)
                        resolveUnresolvedCandidates(armed.snapshot)
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
                                    // Retained so a later join can prove it is
                                    // joining the definition that promoted this
                                    // candidate, not merely the same event id.
                                    verifiedDefinitionHashHex = verified.definitionHashHex,
                                    registryBlockHashHex = verified.blockHashHex,
                                    verifiedDefinitionValidFromEpochSeconds = verified.validFromEpochSeconds,
                                    verifiedDefinitionValidUntilEpochSeconds = verified.validUntilEpochSeconds,
                                )
                            val armed = refreshNearbyEventDiscovery(store, nowEpochMillis())
                            updateVerifiedCard(
                                hash,
                                eventId,
                                verified.validFromEpochSeconds,
                                verified.validUntilEpochSeconds,
                                armed.snapshot,
                            )
                            logResolutionOutcome(hash, eventId, result, attemptNumber, armed.snapshot)
                            publishAndSchedule(armed.snapshot)
                            resolveUnresolvedCandidates(armed.snapshot)
                        }
                    }
                    registryRequests += verification
                }
            }
            if (directEventId != null) {
                // Install the placeholder before launching the completion. Main.immediate
                // can otherwise run the nested launch before `lookup` is assigned.
                lookup = NearbyEventRegistryRequest {}
                registryRequests += lookup
                coroutineScope.launch {
                    handleLookup(NearbyEventIdLookup(true, directEventId, null))
                }
            } else {
                lookup = client.resolveEventIdByCodeHash(hash, handleLookup)
                registryRequests += lookup
            }
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
        verifiedEventIdByHash.keys.retainAll(liveHashes)
        _cards.value = buildList {
            repeat(snapshot.candidateCount) { index ->
                snapshot.candidateAt(index)?.let { candidate ->
                    // Joinability is the SHARED gate's answer, not a rule
                    // restated here (beid#374 review). This projection used to
                    // decide it locally, and the local rule admitted two tiers
                    // the issuer refuses -- a v1-hint-only candidate whose
                    // registry read succeeded, and a RADIO_SELF_VERIFIED
                    // candidate carrying an operator-lookup registration, which
                    // is the forged-envelope case. Both rendered as enabled
                    // cards that tapped straight through to JoinFailed.
                    //
                    // The lesson is narrower than "do not duplicate logic": a
                    // display projection can carry stale DATA and it can also
                    // make its own DECISION, and those are separate audits. The
                    // card's validity window was the first; this was the second,
                    // on the same object, found only by reading the card's
                    // enablement rule against the gate's.
                    val joinable = nearbyCandidateJoinEligibility(
                        candidates = snapshot,
                        eventCodeHashHex = candidate.eventCodeHashHex,
                        nowEpochSeconds = nowEpochSeconds,
                    ) == NearbyEventJoinEligibility.ELIGIBLE
                    // beid#454, the third thing found on this same object: the
                    // fields themselves used to come from verifiedMetadataByHash,
                    // a native cache the shared gate above never consults. A
                    // source-eviction edge case (NearbyEventDiscovery.kt's
                    // MAX_LIVE_SOURCE_COUNT) can drop and re-admit a candidate
                    // while that cache stays empty for it, so a candidate this
                    // gate calls ELIGIBLE could render with no eventIdHex --
                    // Android refusing a card iOS's single-source read shows as
                    // joinable. Reading the candidate directly, as iOS already
                    // does, removes the second source of truth entirely.
                    add(
                        NearbyEventCard(
                            beaconDisplayName = candidate.displayNameAt(0),
                            eventIdHex = candidate.resolvedEventIdHex.takeIf { joinable },
                            displayValidFromEpochSeconds = candidate.definitionValidFromEpochSeconds
                                .takeIf { joinable },
                            displayValidUntilEpochSeconds = candidate.definitionValidUntilEpochSeconds
                                .takeIf { joinable },
                            eventCodeHashHex = candidate.eventCodeHashHex,
                            verification = cardVerification(joinable, candidate.registryStatus),
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
        // A due registry retry is a reason to wake up as much as an expiry is
        // (beid#584). Without it a failed candidate waits for the next beacon
        // to be re-observed, which is the retry trigger the field capture
        // showed was not enough.
        val nextWakeAt = listOfNotNull(
            snapshot.nextExpiryAtEpochMillis,
            definitionExpiryAt,
            snapshot.nextRegistryRetryAtEpochMillis,
        ).minOrNull() ?: return
        val delayMillis = if (nextWakeAt <= now) 0L else nextWakeAt - now
        expiryJob = coroutineScope.launch {
            delay(delayMillis)
            expiryJob = null
            if (disposed) return@launch
            val update = refreshNearbyEventDiscovery(store, nowEpochMillis())
            publishAndSchedule(update.snapshot)
            // The refresh above is what arms a retry whose backoff elapsed;
            // this is what starts it. The shared reducer clears the deadline
            // as it arms, so a retry nothing consumes cannot re-arm this
            // wake-up at a zero delay forever.
            resolveUnresolvedCandidates(update.snapshot)
        }
    }

    /**
     * One line per finished resolution, saying what it answered and when the
     * next attempt is due (beid#584, feeding beid#583).
     *
     * `retry_in_ms` is read back from the shared candidate rather than
     * recomputed here, so the log cannot disagree with the schedule the
     * reducer actually holds.
     */
    private fun logResolutionOutcome(
        hash: String,
        eventIdHex: String?,
        result: NearbyEventRegistryResolutionResult,
        attemptNumber: Int,
        snapshot: NearbyEventCandidates,
    ) {
        if (!BuildConfig.DEBUG) return
        val candidate = (0 until snapshot.candidateCount)
            .mapNotNull(snapshot::candidateAt)
            .firstOrNull { it.eventCodeHashHex == hash }
        val outcome = when (result) {
            NearbyEventRegistryResolutionResult.VERIFIED -> "success"
            NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE -> "rejected_lookup_unavailable"
            NearbyEventRegistryResolutionResult.NOT_REGISTERED -> "rejected_not_registered"
            NearbyEventRegistryResolutionResult.VERIFICATION_UNAVAILABLE -> "rejected_verification_unavailable"
        }
        emitJoinStageDiagnostic(
            log,
            eventIdHex = eventIdHex,
            stage = "registry_resolution",
            outcome = outcome,
            attempt = attemptNumber,
            retryAtEpochMillis = candidate?.registryRetryAtEpochMillis,
        )
    }

    /**
     * What the card says while it is not joinable (beid#584).
     *
     * Reads the shared candidate's registry status rather than counting
     * failures natively, so both platforms describe the same candidate the
     * same way. [joinable] stays the gate's answer and is checked first: a
     * candidate can be REGISTERED_VIA_OPERATOR_LOOKUP and still not joinable
     * (an expired window, or a v2 envelope not yet registry-verified), and
     * that is a wait, not a failure.
     */
    private fun cardVerification(
        joinable: Boolean,
        status: NearbyEventRegistryStatus,
    ): NearbyEventCardVerification = when {
        joinable -> NearbyEventCardVerification.READY
        status == NearbyEventRegistryStatus.NOT_REGISTERED -> NearbyEventCardVerification.NOT_REGISTERED
        status == NearbyEventRegistryStatus.LOOKUP_UNAVAILABLE -> NearbyEventCardVerification.RETRYING
        else -> NearbyEventCardVerification.CHECKING
    }

    /**
     * The shared reducer remains the sole trust predicate. Native code only
     * carries period fields from the already verified context after that
     * reducer exposes REGISTERED_VIA_OPERATOR_LOOKUP for the same candidate.
     *
     * Whether those fields reach a card is decided in [publishAndSchedule], so
     * that a candidate reaching RADIO_SELF_VERIFIED after this ran is still
     * withheld from joining.
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
        if (candidate?.registryStatus == NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP &&
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

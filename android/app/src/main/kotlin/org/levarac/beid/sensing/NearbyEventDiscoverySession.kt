package org.levarac.beid.sensing

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.levarac.parallax.discovery.NearbyEventCandidates
import org.levarac.parallax.discovery.createNearbyEventDiscoveryStore
import org.levarac.parallax.discovery.recordNearbyEventHint
import org.levarac.parallax.discovery.refreshNearbyEventDiscovery
import org.levarac.parallax.discovery.resetNearbyEventDiscovery
import org.levarac.parallax.discovery.beginNearbyEventRegistryResolutionFromHex
import org.levarac.parallax.discovery.completeNearbyEventRegistryResolutionFromHex
import org.levarac.parallax.discovery.NearbyEventRegistryResolutionResult
import org.levarac.parallax.registry.RegistryClient
import org.levarac.parallax.registry.RegistryRequest
import org.levarac.parallax.registry.safeRegistryReadPin

/**
 * Android lifecycle owner for the shared, pure nearby-event discovery store.
 * All mutations are confined to the coordinator's event/callback context.
 */
internal class NearbyEventDiscoverySession(
    private val nowEpochMillis: () -> Long,
    private val coroutineScope: CoroutineScope,
    private val registryClient: RegistryClient? = null,
) {
    private val store = createNearbyEventDiscoveryStore()
    private val _candidates = MutableStateFlow(store.snapshot)
    private var expiryJob: Job? = null
    private var disposed = false
    private val registryRequests = mutableSetOf<RegistryRequest>()

    val candidates: StateFlow<NearbyEventCandidates> = _candidates.asStateFlow()

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

    fun reset() {
        registryRequests.forEach { it.cancel() }
        registryRequests.clear()
        expiryJob?.cancel()
        expiryJob = null
        _candidates.value = resetNearbyEventDiscovery(store).snapshot
    }

    private fun resolveUnresolvedCandidates(snapshot: NearbyEventCandidates) {
        val client = registryClient ?: return
        repeat(snapshot.candidateCount) { index ->
            val candidate = snapshot.candidateAt(index) ?: return@repeat
            val hash = candidate.eventCodeHash.joinToString("") { "%02x".format(it.toInt() and 0xff) }
            if (!beginNearbyEventRegistryResolutionFromHex(store, hash)) return@repeat
            // The whole body runs on coroutineScope's dispatcher (Main.immediate,
            // set by the caller), matching the iOS adapter's `Task { @MainActor }`
            // wrapping. This confines every registryRequests mutation to one
            // thread (resolveEventIdByCodeHash/resolveEventDefinition complete on
            // a background dispatcher per RegistryClient's own scope) and, since
            // launch{} never runs synchronously inline, guarantees `lookup`/
            // `verification` are assigned before this block can read them even
            // on a completion path that calls back before the outer function
            // returns.
            lateinit var lookup: RegistryRequest
            lookup = client.resolveEventIdByCodeHash(hash) { resolution ->
                coroutineScope.launch {
                    registryRequests.remove(lookup)
                    val eventId = resolution.eventIdHex
                    if (!resolution.isSuccess || eventId == null) {
                        val result = if (resolution.errorCode == "event_code_lookup_not_found")
                            NearbyEventRegistryResolutionResult.NOT_REGISTERED
                        else NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE
                        publishAndSchedule(
                            completeNearbyEventRegistryResolutionFromHex(
                                store = store,
                                eventCodeHashHex = hash,
                                result = result,
                                resolvedEventIdHex = null,
                                verifiedDefinitionEventCodeHashHex = null,
                            ).snapshot,
                        )
                        return@launch
                    }
                    lateinit var verification: RegistryRequest
                    verification = client.resolveEventDefinition(eventId, safeRegistryReadPin(), nowEpochMillis() / 1000L) { verified ->
                        coroutineScope.launch {
                            registryRequests.remove(verification)
                            val result = if (verified.isSuccess) NearbyEventRegistryResolutionResult.VERIFIED
                            else NearbyEventRegistryResolutionResult.VERIFICATION_UNAVAILABLE
                            publishAndSchedule(
                                completeNearbyEventRegistryResolutionFromHex(
                                    store = store,
                                    eventCodeHashHex = hash,
                                    result = result,
                                    resolvedEventIdHex = eventId,
                                    verifiedDefinitionEventCodeHashHex = verified.context?.eventCodeHashHex,
                                ).snapshot,
                            )
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
        _candidates.value = snapshot
        expiryJob?.cancel()
        expiryJob = null

        val nextExpiryAt = snapshot.nextExpiryAtEpochMillis ?: return
        val now = nowEpochMillis()
        val delayMillis = if (nextExpiryAt <= now) 0L else nextExpiryAt - now
        expiryJob = coroutineScope.launch {
            delay(delayMillis)
            expiryJob = null
            if (disposed) return@launch
            val update = refreshNearbyEventDiscovery(store, nowEpochMillis())
            publishAndSchedule(update.snapshot)
        }
    }
}

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

/**
 * Android lifecycle owner for the shared, pure nearby-event discovery store.
 * All mutations are confined to the coordinator's event/callback context.
 */
internal class NearbyEventDiscoverySession(
    private val nowEpochMillis: () -> Long,
    private val coroutineScope: CoroutineScope,
) {
    private val store = createNearbyEventDiscoveryStore()
    private val _candidates = MutableStateFlow(store.snapshot)
    private var expiryJob: Job? = null
    private var disposed = false

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
    }

    fun reset() {
        expiryJob?.cancel()
        expiryJob = null
        _candidates.value = resetNearbyEventDiscovery(store).snapshot
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

package org.levarac.parallax.discovery

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private val EVENT_A = byteArrayOf(0, 0, 0, 0, 0, 0, 0, 0x0a)
private val EVENT_B = byteArrayOf(0, 0, 0, 0, 0, 0, 0, 0x0b)

class NearbyEventDiscoveryTest {
    @Test
    fun newStoreStartsWithAnEmptyTruthfulSnapshot() {
        val snapshot = createNearbyEventDiscoveryStore().snapshot

        assertEquals(0, snapshot.candidateCount)
        assertFalse(snapshot.additionalNamesOmitted)
        assertFalse(snapshot.additionalEventsOmitted)
        assertFalse(snapshot.hasLocallyEvictedSources)
        assertNull(snapshot.nextExpiryAtEpochMillis)
    }

    @Test
    fun sameHashFromMultiplePeripheralsMergesIntoOneCandidateWithoutInventingTrust() {
        val store = createNearbyEventDiscoveryStore()
        recordHint(store, "peripheral-b", "Beta", EVENT_A, census = byteArrayOf(2), now = 20L)
        val update = recordHint(store, "peripheral-a", "Alpha", EVENT_A, census = byteArrayOf(1), now = 10L)

        assertTrue(update.acceptedHint)
        assertTrue(update.changed)
        assertEquals(1, update.snapshot.candidateCount)
        val candidate = assertNotNull(update.snapshot.candidateAt(0))
        assertContentEquals(EVENT_A, candidate.eventCodeHash)
        assertEquals(10L, candidate.firstSeenAtEpochMillis)
        assertEquals(20L, candidate.lastSeenAtEpochMillis)
        assertEquals(2, candidate.sourceCount)
        assertEquals("peripheral-a", assertNotNull(candidate.sourceAt(0)).peripheralId)
        assertEquals("peripheral-b", assertNotNull(candidate.sourceAt(1)).peripheralId)
        assertEquals(2, candidate.distinctDisplayNameCount)
        assertEquals("Alpha", candidate.displayNameAt(0))
        assertEquals("Beta", candidate.displayNameAt(1))
        assertTrue(candidate.hasDisplayNameConflict)
        assertEquals(NearbyEventTrustStatus.UNAUTHENTICATED_B005_HINT, candidate.trustStatus)
        assertEquals(
            NearbyEventRegistryStatus.UNAVAILABLE_FROM_EVENT_CODE_HASH,
            candidate.registryStatus,
            "an 8-byte B005 hash must never be presented as a resolved 32-byte registry Event ID",
        )
    }

    @Test
    fun sameHashAndPeripheralUpdatesOneSourceWhilePreservingItsFirstSeenTime() {
        val store = createNearbyEventDiscoveryStore()
        recordHint(store, "peripheral-a", "Old name", EVENT_A, census = byteArrayOf(1), now = 10L)
        recordHint(store, "peripheral-a", "New name", EVENT_A, census = byteArrayOf(9), now = 30L)

        val candidate = assertNotNull(store.snapshot.candidateAt(0))
        assertEquals(1, candidate.sourceCount)
        val source = assertNotNull(candidate.sourceAt(0))
        assertEquals("New name", source.eventDisplayName)
        assertContentEquals(byteArrayOf(9), assertNotNull(source.census))
        assertEquals(10L, source.firstSeenAtEpochMillis)
        assertEquals(30L, source.lastSeenAtEpochMillis)
        assertEquals(1, candidate.distinctDisplayNameCount)
        assertFalse(candidate.hasDisplayNameConflict)
    }

    @Test
    fun differentHashesFromTheSamePeripheralRemainSeparateCandidates() {
        val store = createNearbyEventDiscoveryStore()
        recordHint(store, "peripheral-a", "Event A", EVENT_A, now = 10L)
        recordHint(store, "peripheral-a", "Event B", EVENT_B, now = 20L)

        assertEquals(2, store.snapshot.candidateCount)
        assertContentEquals(EVENT_A, assertNotNull(store.snapshot.candidateAt(0)).eventCodeHash)
        assertContentEquals(EVENT_B, assertNotNull(store.snapshot.candidateAt(1)).eventCodeHash)
    }

    @Test
    fun sourceExpiresAtTheExactFiveMinuteBoundaryAndRefreshPublishesTheChange() {
        val store = createNearbyEventDiscoveryStore()
        recordHint(store, "peripheral-a", "Event A", EVENT_A, now = 1_000L)

        val stillLive = refreshNearbyEventDiscovery(store, nowEpochMillis = 300_999L)
        assertFalse(stillLive.changed)
        assertEquals(1, stillLive.snapshot.candidateCount)
        assertEquals(301_000L, stillLive.snapshot.nextExpiryAtEpochMillis)

        val expired = refreshNearbyEventDiscovery(store, nowEpochMillis = 301_000L)
        assertTrue(expired.changed)
        assertEquals(0, expired.snapshot.candidateCount)
        assertNull(expired.snapshot.nextExpiryAtEpochMillis)
    }

    @Test
    fun overflowMarkerUpdatesGlobalOmissionFactsButNeverBecomesACandidate() {
        val store = createNearbyEventDiscoveryStore()

        val update = recordNearbyEventHint(
            store = store,
            peripheralId = "",
            eventDisplayName = "",
            eventCodeHash = byteArrayOf(),
            census = null,
            additionalNamesOmitted = true,
            additionalEventsOmitted = true,
            observedAtEpochMillis = 7L,
        )

        assertFalse(update.acceptedHint)
        assertTrue(update.changed, "omission facts are processed before candidate validation")
        assertEquals(0, update.snapshot.candidateCount)
        assertTrue(update.snapshot.additionalNamesOmitted)
        assertTrue(update.snapshot.additionalEventsOmitted)
    }

    @Test
    fun omissionFlagsClearAtExactTtlFromLastBearingObservationWithoutReset() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(
            store = store,
            peripheralId = "peripheral-a",
            eventDisplayName = "Event A",
            eventCodeHash = EVENT_A,
            census = null,
            additionalNamesOmitted = true,
            additionalEventsOmitted = true,
            observedAtEpochMillis = 1_000L,
        )

        // A later ordinary observation keeps the candidate alive, but must
        // not extend omission facts that it did not itself carry.
        recordHint(store, "peripheral-a", "Event A", EVENT_A, now = 250_000L)

        val beforeBoundary = refreshNearbyEventDiscovery(store, nowEpochMillis = 300_999L)
        assertTrue(beforeBoundary.snapshot.additionalNamesOmitted)
        assertTrue(beforeBoundary.snapshot.additionalEventsOmitted)
        assertEquals(1, beforeBoundary.snapshot.candidateCount)

        val atBoundary = refreshNearbyEventDiscovery(store, nowEpochMillis = 301_000L)
        assertTrue(atBoundary.changed)
        assertFalse(atBoundary.snapshot.additionalNamesOmitted)
        assertFalse(atBoundary.snapshot.additionalEventsOmitted)
        assertEquals(
            1,
            atBoundary.snapshot.candidateCount,
            "flag TTL is measured from the last bearing observation, independently of the live candidate TTL",
        )
    }

    @Test
    fun boundaryRejectsOnlyInvalidIdentityShapeAndTime() {
        val store = createNearbyEventDiscoveryStore()

        assertFalse(recordHint(store, " ", "Name", EVENT_A, now = 0L).acceptedHint)
        assertFalse(recordHint(store, "p", "Name", byteArrayOf(1, 2, 3), now = 0L).acceptedHint)
        assertFalse(recordHint(store, "p", "Name", EVENT_A, now = -1L).acceptedHint)
        assertTrue(
            recordHint(store, "p", "", EVENT_A, census = byteArrayOf(), now = 0L).acceptedHint,
            "Barnard owns display-name and census semantics; shared only validates the discovery identity boundary",
        )
        assertEquals(1, store.snapshot.candidateCount)
    }

    @Test
    fun resetClearsCandidatesOmissionFactsAndLocalEvictionHistory() {
        val store = createNearbyEventDiscoveryStore()
        recordHint(store, "p", "Event A", EVENT_A, now = 1L)
        recordNearbyEventHint(
            store,
            peripheralId = "",
            eventDisplayName = "",
            eventCodeHash = byteArrayOf(),
            census = null,
            additionalNamesOmitted = true,
            additionalEventsOmitted = true,
            observedAtEpochMillis = 2L,
        )

        val reset = resetNearbyEventDiscovery(store)

        assertTrue(reset.changed)
        assertEquals(0, reset.snapshot.candidateCount)
        assertFalse(reset.snapshot.additionalNamesOmitted)
        assertFalse(reset.snapshot.additionalEventsOmitted)
        assertFalse(reset.snapshot.hasLocallyEvictedSources)
        assertNull(reset.snapshot.nextExpiryAtEpochMillis)
    }

    private fun recordHint(
        store: NearbyEventDiscoveryStore,
        peripheralId: String,
        name: String,
        hash: ByteArray,
        census: ByteArray? = null,
        now: Long,
    ): NearbyEventDiscoveryUpdate = recordNearbyEventHint(
        store = store,
        peripheralId = peripheralId,
        eventDisplayName = name,
        eventCodeHash = hash,
        census = census,
        additionalNamesOmitted = false,
        additionalEventsOmitted = false,
        observedAtEpochMillis = now,
    )
}

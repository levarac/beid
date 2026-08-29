package org.levarac.parallax.discovery

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

private const val GLOBAL_SOURCE_CAP = 256

class NearbyEventDiscoveryOwnershipTest {
    @Test
    fun byteArraysAreCopiedOnEntryAndEveryGetter() {
        val store = createNearbyEventDiscoveryStore()
        val inputHash = hashFor(7)
        val inputCensus = byteArrayOf(1, 2, 3)
        record(store, inputHash, "p", inputCensus, now = 10L)

        inputHash[7] = 99
        inputCensus[0] = 99
        val snapshot = store.snapshot
        val candidate = assertNotNull(snapshot.candidateAt(0))
        val source = assertNotNull(candidate.sourceAt(0))
        assertContentEquals(hashFor(7), candidate.eventCodeHash)
        assertContentEquals(byteArrayOf(1, 2, 3), assertNotNull(source.census))

        candidate.eventCodeHash[7] = 88
        assertNotNull(source.census)[0] = 88
        assertContentEquals(hashFor(7), assertNotNull(snapshot.candidateAt(0)).eventCodeHash)
        assertContentEquals(byteArrayOf(1, 2, 3), assertNotNull(assertNotNull(candidate.sourceAt(0)).census))
    }

    @Test
    fun publishedSnapshotDoesNotChangeWhenTheStoreChangesLater() {
        val store = createNearbyEventDiscoveryStore()
        record(store, hashFor(1), "p-1", null, now = 1L)
        val earlier = store.snapshot

        record(store, hashFor(2), "p-2", null, now = 2L)

        assertEquals(1, earlier.candidateCount)
        assertContentEquals(hashFor(1), assertNotNull(earlier.candidateAt(0)).eventCodeHash)
        assertEquals(2, store.snapshot.candidateCount)
    }

    @Test
    fun sourceCapIsGlobalAcrossCandidatesAndAcceptsTheNewcomer() {
        val store = createNearbyEventDiscoveryStore()
        repeat(GLOBAL_SOURCE_CAP) { index ->
            record(store, hashFor(index / 2), peripheralFor(index), null, now = index.toLong())
        }

        val newcomerHash = hashFor(999)
        val update = record(store, newcomerHash, "newcomer", null, now = 10_000L)

        assertTrue(update.acceptedHint)
        assertTrue(update.snapshot.hasLocallyEvictedSources)
        assertEquals(GLOBAL_SOURCE_CAP, sourceCount(update.snapshot))
        assertTrue(sourceKeys(update.snapshot).contains(newcomerHash.toHex() to "newcomer"))
        assertFalse(sourceKeys(update.snapshot).contains(hashFor(0).toHex() to peripheralFor(0)))
    }

    @Test
    fun expiredSourcesArePrunedBeforeCapacityEviction() {
        val store = createNearbyEventDiscoveryStore()
        repeat(GLOBAL_SOURCE_CAP) { index ->
            record(store, hashFor(index), peripheralFor(index), null, now = 0L)
        }

        val update = record(store, hashFor(999), "newcomer", null, now = 300_000L)

        assertEquals(1, sourceCount(update.snapshot))
        assertFalse(update.snapshot.hasLocallyEvictedSources, "TTL pruning is not local capacity eviction")
        assertTrue(sourceKeys(update.snapshot).contains(hashFor(999).toHex() to "newcomer"))
    }

    @Test
    fun equalLastSeenEvictsByUnsignedHashThenPeripheralId() {
        val store = createNearbyEventDiscoveryStore()
        repeat(GLOBAL_SOURCE_CAP) { index ->
            record(store, hashFor(1), peripheralFor(index), null, now = 5L)
        }

        record(store, hashFor(2), "newcomer", null, now = 5L)

        val keys = sourceKeys(store.snapshot)
        assertFalse(keys.contains(hashFor(1).toHex() to peripheralFor(0)))
        assertTrue(keys.contains(hashFor(1).toHex() to peripheralFor(1)))
        assertTrue(keys.contains(hashFor(2).toHex() to "newcomer"))
    }

    @Test
    fun candidatesSourcesAndNamesHaveStableIndependentOrdering() {
        val store = createNearbyEventDiscoveryStore()
        recordNamed(store, byteArrayOf(-1, 0, 0, 0, 0, 0, 0, 0), "z", "Zulu")
        recordNamed(store, byteArrayOf(0, 0, 0, 0, 0, 0, 0, 1), "b", "beta")
        recordNamed(store, byteArrayOf(0, 0, 0, 0, 0, 0, 0, 1), "a", "Alpha")

        val first = assertNotNull(store.snapshot.candidateAt(0))
        val second = assertNotNull(store.snapshot.candidateAt(1))
        assertContentEquals(byteArrayOf(0, 0, 0, 0, 0, 0, 0, 1), first.eventCodeHash)
        assertContentEquals(byteArrayOf(-1, 0, 0, 0, 0, 0, 0, 0), second.eventCodeHash)
        assertEquals("a", assertNotNull(first.sourceAt(0)).peripheralId)
        assertEquals("b", assertNotNull(first.sourceAt(1)).peripheralId)
        assertEquals("Alpha", first.displayNameAt(0))
        assertEquals("beta", first.displayNameAt(1))
    }

    private fun record(
        store: NearbyEventDiscoveryStore,
        hash: ByteArray,
        peripheralId: String,
        census: ByteArray?,
        now: Long,
    ): NearbyEventDiscoveryUpdate = recordNearbyEventHint(
        store,
        peripheralId = peripheralId,
        eventDisplayName = "Event",
        eventCodeHash = hash,
        census = census,
        additionalNamesOmitted = false,
        additionalEventsOmitted = false,
        observedAtEpochMillis = now,
    )

    private fun recordNamed(store: NearbyEventDiscoveryStore, hash: ByteArray, peripheralId: String, name: String) {
        recordNearbyEventHint(
            store,
            peripheralId = peripheralId,
            eventDisplayName = name,
            eventCodeHash = hash,
            census = null,
            additionalNamesOmitted = false,
            additionalEventsOmitted = false,
            observedAtEpochMillis = 1L,
        )
    }

    private fun sourceCount(snapshot: NearbyEventCandidates): Int =
        (0 until snapshot.candidateCount).sumOf { index ->
            assertNotNull(snapshot.candidateAt(index)).sourceCount
        }

    private fun sourceKeys(snapshot: NearbyEventCandidates): Set<Pair<String, String>> = buildSet {
        repeat(snapshot.candidateCount) { candidateIndex ->
            val candidate = assertNotNull(snapshot.candidateAt(candidateIndex))
            repeat(candidate.sourceCount) { sourceIndex ->
                add(candidate.eventCodeHash.toHex() to assertNotNull(candidate.sourceAt(sourceIndex)).peripheralId)
            }
        }
    }

    private fun hashFor(index: Int): ByteArray = ByteArray(8).also { bytes ->
        bytes[4] = (index ushr 24).toByte()
        bytes[5] = (index ushr 16).toByte()
        bytes[6] = (index ushr 8).toByte()
        bytes[7] = index.toByte()
    }

    private fun peripheralFor(index: Int): String = "p-${index.toString().padStart(3, '0')}"

    private fun ByteArray.toHex(): String = joinToString("") { byte ->
        byte.toUByte().toString(16).padStart(2, '0')
    }
}

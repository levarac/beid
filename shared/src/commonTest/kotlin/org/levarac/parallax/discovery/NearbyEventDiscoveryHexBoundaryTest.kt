package org.levarac.parallax.discovery

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * `recordNearbyEventHintFromHex` exists only because Swift Export emits a
 * trapping `ByteArray` constructor, so iOS cannot hand raw bytes across the
 * boundary. It is a transport shim, not a second decision: whatever it
 * accepts must produce exactly the state the byte-oriented entry point
 * produces for the same bytes. These tests pin that equivalence, plus the
 * one place the shim deliberately differs — malformed hex is rejected by
 * throwing, where the byte path has no way to be malformed at all.
 */
class NearbyEventDiscoveryHexBoundaryTest {
    @Test
    fun hexEntryPointProducesTheSameStateAsTheByteEntryPoint() {
        val hash = byteArrayOf(0, 1, 2, 3, 4, 5, 6, 7)
        val census = byteArrayOf(0x9.toByte(), 0xf0.toByte(), 0x00, 0xff.toByte())

        val viaBytes = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(
            store = viaBytes,
            peripheralId = "peripheral-a",
            eventDisplayName = "Community night",
            eventCodeHash = hash,
            census = census,
            additionalNamesOmitted = false,
            additionalEventsOmitted = false,
            observedAtEpochMillis = 1_000L,
        )

        val viaHex = createNearbyEventDiscoveryStore()
        val update = recordNearbyEventHintFromHex(
            store = viaHex,
            peripheralId = "peripheral-a",
            eventDisplayName = "Community night",
            eventCodeHashHex = "0001020304050607",
            censusHex = "09f000ff",
            additionalNamesOmitted = false,
            additionalEventsOmitted = false,
            observedAtEpochMillis = 1_000L,
        )

        assertTrue(update.acceptedHint)
        val expected = assertNotNull(viaBytes.snapshot.candidateAt(0))
        val actual = assertNotNull(viaHex.snapshot.candidateAt(0))
        assertContentEquals(expected.eventCodeHash, actual.eventCodeHash)
        assertContentEquals(hash, actual.eventCodeHash)
        assertEquals(expected.displayNameAt(0), actual.displayNameAt(0))
        val expectedSource = assertNotNull(expected.sourceAt(0))
        val actualSource = assertNotNull(actual.sourceAt(0))
        assertEquals(expectedSource.peripheralId, actualSource.peripheralId)
        assertContentEquals(assertNotNull(expectedSource.census), assertNotNull(actualSource.census))
        assertContentEquals(census, assertNotNull(actualSource.census))
        assertEquals(expected.registryStatus, actual.registryStatus)
        assertEquals(
            NearbyEventRegistryStatus.UNRESOLVED,
            actual.registryStatus,
        )
    }

    @Test
    fun nullCensusHexStaysNullRatherThanBecomingEmptyBytes() {
        val store = createNearbyEventDiscoveryStore()

        recordNearbyEventHintFromHex(
            store = store,
            peripheralId = "peripheral-a",
            eventDisplayName = "Event",
            eventCodeHashHex = "0001020304050607",
            censusHex = null,
            additionalNamesOmitted = false,
            additionalEventsOmitted = false,
            observedAtEpochMillis = 1_000L,
        )

        val source = assertNotNull(assertNotNull(store.snapshot.candidateAt(0)).sourceAt(0))
        assertNull(source.census)
    }

    /**
     * Barnard's overflow marker reaches iOS as an empty `Data`, which becomes
     * an empty hex string. That must decode to an empty array and travel the
     * marker path — omission facts updated, no candidate — not throw.
     */
    @Test
    fun emptyHexIsTheOverflowMarkerAndNotAMalformedValue() {
        val store = createNearbyEventDiscoveryStore()

        val update = recordNearbyEventHintFromHex(
            store = store,
            peripheralId = "",
            eventDisplayName = "",
            eventCodeHashHex = "",
            censusHex = null,
            additionalNamesOmitted = true,
            additionalEventsOmitted = true,
            observedAtEpochMillis = 2_000L,
        )

        assertFalse(update.acceptedHint)
        val snapshot = store.snapshot
        assertEquals(0, snapshot.candidateCount)
        assertTrue(snapshot.additionalNamesOmitted)
        assertTrue(snapshot.additionalEventsOmitted)
    }

    /**
     * iOS sends lowercase, but the function is public and hex is
     * case-insensitive by convention. Pinning this stops a later "tidy-up"
     * from narrowing the accepted set without noticing.
     */
    @Test
    fun uppercaseHexDecodesToTheSameBytesAsLowercase() {
        val store = createNearbyEventDiscoveryStore()

        recordNearbyEventHintFromHex(
            store = store,
            peripheralId = "peripheral-a",
            eventDisplayName = "Event",
            eventCodeHashHex = "AABBCCDD00112233",
            censusHex = "0F",
            additionalNamesOmitted = false,
            additionalEventsOmitted = false,
            observedAtEpochMillis = 1_000L,
        )

        val candidate = assertNotNull(store.snapshot.candidateAt(0))
        assertContentEquals(
            byteArrayOf(
                0xaa.toByte(), 0xbb.toByte(), 0xcc.toByte(), 0xdd.toByte(),
                0x00, 0x11, 0x22, 0x33,
            ),
            candidate.eventCodeHash,
        )
        assertContentEquals(
            byteArrayOf(0x0f),
            assertNotNull(assertNotNull(candidate.sourceAt(0)).census),
        )
    }

    /**
     * The byte entry point is total — a wrong-length hash is reported as
     * `acceptedHint = false`, never an exception. The hex shim cannot be
     * total, because "not hex" has no byte representation to reject. This
     * asymmetry is deliberate and is recorded here so it stays a decision:
     * the only production caller builds the string with `%02x`, so a throw
     * means a programming error, not bad input from the radio.
     */
    @Test
    fun oddLengthHexIsRejectedByThrowing() {
        val store = createNearbyEventDiscoveryStore()

        assertFailsWith<IllegalArgumentException> {
            recordNearbyEventHintFromHex(
                store = store,
                peripheralId = "peripheral-a",
                eventDisplayName = "Event",
                eventCodeHashHex = "000102030405060",
                censusHex = null,
                additionalNamesOmitted = false,
                additionalEventsOmitted = false,
                observedAtEpochMillis = 1_000L,
            )
        }
    }

    @Test
    fun nonHexCharactersAreRejectedByThrowing() {
        val store = createNearbyEventDiscoveryStore()

        assertFailsWith<IllegalArgumentException> {
            recordNearbyEventHintFromHex(
                store = store,
                peripheralId = "peripheral-a",
                eventDisplayName = "Event",
                eventCodeHashHex = "00010203040506zz",
                censusHex = null,
                additionalNamesOmitted = false,
                additionalEventsOmitted = false,
                observedAtEpochMillis = 1_000L,
            )
        }
    }

    @Test
    fun aMalformedCensusIsRejectedRatherThanSilentlyDroppedToNull() {
        val store = createNearbyEventDiscoveryStore()

        assertFailsWith<IllegalArgumentException> {
            recordNearbyEventHintFromHex(
                store = store,
                peripheralId = "peripheral-a",
                eventDisplayName = "Event",
                eventCodeHashHex = "0001020304050607",
                censusHex = "f",
                additionalNamesOmitted = false,
                additionalEventsOmitted = false,
                observedAtEpochMillis = 1_000L,
            )
        }
        assertEquals(0, store.snapshot.candidateCount)
    }
}

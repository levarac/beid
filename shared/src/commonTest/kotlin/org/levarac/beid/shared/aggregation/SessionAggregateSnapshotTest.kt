package org.levarac.beid.shared.aggregation

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SessionAggregateSnapshotTest {

    @Test
    fun emptySessionRoundTripsToStableCanonicalBytes() {
        val session = aggregateObservationsForSession(
            createAggregationObservationInput(),
            windowsPerBand = 4,
        )
        assertTrue(session.isSuccess)

        val encoded = encodeSessionAggregateSnapshot(session)
        assertTrue(encoded.isSuccess)
        val snapshot = assertNotNull(encoded.snapshotText)
        val expected = """
            beid-session-aggregate-snapshot\t1
            device-count\t0
            observation-count\t0
            observations-without-display-id-count\t0
            mutual-device-count\t0
            mutual-observation-count\t0
            mutual-observations-without-display-id-count\t0
            windows\t0
            bands\t0
            end
        """.trimIndent().replace("\\t", "\t") + "\n"
        assertContentEquals(expected.encodeToByteArray(), snapshot.encodeToByteArray())

        val decoded = decodeSessionAggregateSnapshot(snapshot)
        assertTrue(decoded.isSuccess)
        val restored = assertNotNull(decoded.aggregate)
        assertEquals(0, restored.windowCount)
        assertEquals(0, restored.bandCount)
        assertEquals(0, restored.deviceCount)
        assertEquals(snapshot, encodeSessionAggregateSnapshot(restored).snapshotText)
    }

    @Test
    fun multiWindowMultiBandSessionRoundTripsToStableCanonicalBytes() {
        val input = createAggregationObservationInput()
        assertTrue(addAggregationObservation(input, 100L, "rpi-a1", "device-a", true))
        assertTrue(addAggregationObservation(input, 100L, "rpi-b1", "device-b", false))
        assertTrue(addAggregationObservation(input, 101L, "rpi-a2", "device-a", true))
        assertTrue(addAggregationObservation(input, 101L, "rpi-c1", null, false))
        assertTrue(addAggregationObservation(input, 104L, "rpi-d1", "device-d", false))

        val session = aggregateObservationsForSession(input, windowsPerBand = 4)
        assertTrue(session.isSuccess)
        assertEquals(3, session.windowCount)
        assertEquals(2, session.bandCount)

        val encoded = encodeSessionAggregateSnapshot(session)
        assertTrue(encoded.isSuccess)
        val snapshot = assertNotNull(encoded.snapshotText)
        val expected = """
            beid-session-aggregate-snapshot\t1
            device-count\t3
            observation-count\t5
            observations-without-display-id-count\t1
            mutual-device-count\t1
            mutual-observation-count\t2
            mutual-observations-without-display-id-count\t0
            windows\t3
            window\t100\t2\t2\t1\t1
            window\t101\t2\t2\t1\t1
            window\t104\t1\t1\t0\t0
            bands\t2
            band\t25\t4\t2\t4\t1\t1\t2\t0
            band\t26\t4\t1\t1\t0\t0\t0\t0
            end
        """.trimIndent().replace("\\t", "\t") + "\n"
        assertContentEquals(expected.encodeToByteArray(), snapshot.encodeToByteArray())

        val decoded = decodeSessionAggregateSnapshot(snapshot)
        assertTrue(decoded.isSuccess)
        val restored = assertNotNull(decoded.aggregate)
        assertEquals(session.deviceCount, restored.deviceCount)
        assertEquals(session.observationCount, restored.observationCount)
        assertEquals(session.observationsWithoutDisplayIdCount, restored.observationsWithoutDisplayIdCount)
        assertEquals(session.mutualDeviceCount, restored.mutualDeviceCount)
        assertEquals(session.mutualObservationCount, restored.mutualObservationCount)
        assertEquals(
            session.mutualObservationsWithoutDisplayIdCount,
            restored.mutualObservationsWithoutDisplayIdCount,
        )
        assertEquals(session.windowCount, restored.windowCount)
        for (index in 0 until session.windowCount) {
            val original = assertNotNull(session.windowAt(index))
            val roundTripped = assertNotNull(restored.windowAt(index))
            assertEquals(original.windowIndex, roundTripped.windowIndex)
            assertEquals(original.peerCount, roundTripped.peerCount)
            assertEquals(original.observationCount, roundTripped.observationCount)
            assertEquals(original.mutualPeerCount, roundTripped.mutualPeerCount)
            assertEquals(original.mutualObservationCount, roundTripped.mutualObservationCount)
        }
        assertEquals(session.bandCount, restored.bandCount)
        for (index in 0 until session.bandCount) {
            val original = assertNotNull(session.bandAt(index))
            val roundTripped = assertNotNull(restored.bandAt(index))
            assertEquals(original.bandIndex, roundTripped.bandIndex)
            assertEquals(original.windowsPerBand, roundTripped.windowsPerBand)
            assertEquals(original.deviceCount, roundTripped.deviceCount)
            assertEquals(original.observationCount, roundTripped.observationCount)
            assertEquals(
                original.observationsWithoutDisplayIdCount,
                roundTripped.observationsWithoutDisplayIdCount,
            )
            assertEquals(original.mutualDeviceCount, roundTripped.mutualDeviceCount)
            assertEquals(original.mutualObservationCount, roundTripped.mutualObservationCount)
            assertEquals(
                original.mutualObservationsWithoutDisplayIdCount,
                roundTripped.mutualObservationsWithoutDisplayIdCount,
            )
        }
        assertEquals(snapshot, encodeSessionAggregateSnapshot(restored).snapshotText)
    }

    @Test
    fun aSessionWithOnlyDisplayIdLessObservationsRoundTripsWithAZeroDeviceCount() {
        val input = createAggregationObservationInput()
        assertTrue(addAggregationObservation(input, 900L, "rpi-a", null, true))
        assertTrue(addAggregationObservation(input, 901L, "rpi-b", null, false))

        val session = aggregateObservationsForSession(input, windowsPerBand = 4)
        val encoded = encodeSessionAggregateSnapshot(session)
        val snapshot = assertNotNull(encoded.snapshotText)
        val decoded = decodeSessionAggregateSnapshot(snapshot)
        assertTrue(decoded.isSuccess)
        val restored = assertNotNull(decoded.aggregate)
        assertEquals(0, restored.deviceCount)
        assertEquals(2, restored.observationCount)
        assertEquals(2, restored.observationsWithoutDisplayIdCount)
    }

    @Test
    fun encodingAFailedAggregateIsRejectedRatherThanProducingAnEmptySnapshot() {
        val input = createAggregationObservationInput()
        assertTrue(addAggregationObservation(input, 1L, "rpi-a", "device-a", true))
        val failed = aggregateObservationsForSession(input, windowsPerBand = 0)
        assertFalse(failed.isSuccess)

        val encoded = encodeSessionAggregateSnapshot(failed)
        assertFalse(encoded.isSuccess)
        assertNull(encoded.snapshotText)
        assertEquals("aggregate_not_successful", encoded.errorCode)
    }

    @Test
    fun corruptOrTamperedSnapshotsAreRejectedInsteadOfBecomingAnEmptyOrPartiallyTrustedAggregate() {
        val canonical = canonicalTwoWindowOneBandSnapshot()
        val corruptions = mapOf(
            "empty" to "",
            "unknown version" to canonical.replaceFirst(
                "beid-session-aggregate-snapshot\t1",
                "beid-session-aggregate-snapshot\t2",
            ),
            "CRLF" to canonical.replace("\n", "\r\n"),
            "missing final LF" to canonical.dropLast(1),
            "noncanonical count" to canonical.replaceFirst("device-count\t1", "device-count\t01"),
            "negative count" to canonical.replaceFirst("device-count\t1", "device-count\t-1"),
            "data after end" to canonical + "trailing\n",
            "truncated record" to canonical.dropLast(10),
            "reordered windows" to run {
                val lines = canonical.trimEnd('\n').split('\n').toMutableList()
                val firstWindowIndex = lines.indexOfFirst { it.startsWith("window\t") }
                val secondWindowIndex = lines.indexOfFirst {
                    it.startsWith("window\t") && lines.indexOf(it) != firstWindowIndex
                }
                val tmp = lines[firstWindowIndex]
                lines[firstWindowIndex] = lines[secondWindowIndex]
                lines[secondWindowIndex] = tmp
                lines.joinToString("\n") + "\n"
            },
            "device count exceeds what observations support" to canonical.replaceFirst(
                "device-count\t1",
                "device-count\t99",
            ),
            "mutual device count exceeds all-observation device count" to canonical.replaceFirst(
                "mutual-device-count\t1",
                "mutual-device-count\t99",
            ),
        )

        corruptions.forEach { (name, corrupted) ->
            val decoded = decodeSessionAggregateSnapshot(corrupted)
            assertFalse(decoded.isSuccess, name)
            assertNull(decoded.aggregate, name)
            assertNotNull(decoded.errorCode, name)
        }
    }

    @Test
    fun bandsDeclaringDifferentWindowsPerBandAreRejected() {
        val forged = """
            beid-session-aggregate-snapshot\t1
            device-count\t0
            observation-count\t0
            observations-without-display-id-count\t0
            mutual-device-count\t0
            mutual-observation-count\t0
            mutual-observations-without-display-id-count\t0
            windows\t0
            bands\t2
            band\t0\t4\t0\t0\t0\t0\t0\t0
            band\t1\t8\t0\t0\t0\t0\t0\t0
            end
        """.trimIndent().replace("\\t", "\t") + "\n"

        val decoded = decodeSessionAggregateSnapshot(forged)
        assertFalse(decoded.isSuccess)
        assertNull(decoded.aggregate)
    }

    @Test
    fun oversizedSnapshotTextIsRejectedOnDecodeRatherThanParsed() {
        val oversized = "a".repeat(MAX_SESSION_AGGREGATE_SNAPSHOT_BYTES + 1)
        val decoded = decodeSessionAggregateSnapshot(oversized)
        assertFalse(decoded.isSuccess)
        assertNull(decoded.aggregate)
        assertEquals("snapshot_too_large", decoded.errorCode)
    }

    private fun canonicalTwoWindowOneBandSnapshot(): String {
        val input = createAggregationObservationInput()
        assertTrue(addAggregationObservation(input, 0L, "rpi-a", "device-a", true))
        assertTrue(addAggregationObservation(input, 1L, "rpi-b", null, false))
        val session = aggregateObservationsForSession(input, windowsPerBand = 4)
        return assertNotNull(encodeSessionAggregateSnapshot(session).snapshotText)
    }
}

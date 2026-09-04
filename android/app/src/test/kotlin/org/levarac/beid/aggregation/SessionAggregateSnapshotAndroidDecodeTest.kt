package org.levarac.beid.aggregation

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import org.levarac.beid.shared.aggregation.decodeSessionAggregateSnapshot
import org.levarac.beid.shared.aggregation.encodeSessionAggregateSnapshot

/**
 * Golden-vector test proving Android's `:app` module — running on the JVM
 * host, through its own `project(":shared")` dependency, not a synthetic
 * commonTest-only target — correctly decodes the exact same literal
 * `SessionAggregate` snapshot text
 * `SessionAggregateSnapshotTest.multiWindowMultiBandSessionRoundTripsToStableCanonicalBytes`
 * already proves round-trips in `shared`'s own `commonTest` suite
 * (`shared/src/commonTest/kotlin/org/levarac/beid/shared/aggregation/SessionAggregateSnapshotTest.kt`).
 * The literal string below is copied verbatim from that shared test, not
 * retyped, so this is traceably the same vector, not a new one that happens
 * to look similar (beid#122).
 *
 * **What this test proves, and what it does not**: this proves codec parity
 * — Android's JVM host decodes/re-encodes this exact fixture identically to
 * every other host `shared`'s own commonTest suite already covers. It does
 * **NOT** prove Android will ever compute these numbers from a real physical
 * session: Android has no production code path that calls
 * `aggregateObservationsForSession` today. `EventJoinCoordinator` and
 * `ProofRecordingBridge` only ever carry a bare `peersVerified` Int, nothing
 * per-observation, so no Android proof has (or can yet have) a persisted
 * session-aggregate snapshot to decode in production — that gap is tracked
 * by beid#327, not this test. Do not cite this test as end-to-end
 * production parity evidence.
 */
class SessionAggregateSnapshotAndroidDecodeTest {
    @Test
    fun decodesTheSharedMultiWindowMultiBandGoldenVectorWithTheExpectedFieldValues() {
        val goldenVectorSnapshotText = """
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

        val decoded = decodeSessionAggregateSnapshot(goldenVectorSnapshotText)

        assertTrue(decoded.isSuccess, decoded.errorCode)
        val aggregate = assertNotNull(decoded.aggregate)

        assertEquals(3, aggregate.deviceCount)
        assertEquals(5, aggregate.observationCount)
        assertEquals(1, aggregate.observationsWithoutDisplayIdCount)
        assertEquals(1, aggregate.mutualDeviceCount)
        assertEquals(2, aggregate.mutualObservationCount)
        assertEquals(0, aggregate.mutualObservationsWithoutDisplayIdCount)

        assertEquals(3, aggregate.windowCount)
        val secondWindow = assertNotNull(aggregate.windowAt(1))
        assertEquals(101L, secondWindow.windowIndex)
        assertEquals(2, secondWindow.peerCount)
        assertEquals(1, secondWindow.mutualPeerCount)

        assertEquals(2, aggregate.bandCount)
        val firstBand = assertNotNull(aggregate.bandAt(0))
        assertEquals(25L, firstBand.bandIndex)
        assertEquals(4, firstBand.windowsPerBand)
        assertEquals(2, firstBand.deviceCount)
        assertEquals(4, firstBand.observationCount)
        assertEquals(1, firstBand.mutualDeviceCount)
        assertEquals(2, firstBand.mutualObservationCount)

        val secondBand = assertNotNull(aggregate.bandAt(1))
        assertEquals(26L, secondBand.bandIndex)
        assertEquals(1, secondBand.deviceCount)

        // Re-encoding must reproduce the exact same canonical bytes — this is what
        // `decodeSessionAggregateSnapshot` itself requires to accept a snapshot at all
        // (see its own doc comment), so this also indirectly confirms decode succeeded
        // via the real strict path, not a lenient one.
        assertEquals(goldenVectorSnapshotText, encodeSessionAggregateSnapshot(aggregate).snapshotText)
    }
}

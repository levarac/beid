package org.levarac.beid.persistence

import java.nio.file.Files
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.levarac.beid.shared.aggregation.addAggregationObservation
import org.levarac.beid.shared.aggregation.aggregateObservationsForSession
import org.levarac.beid.shared.aggregation.createAggregationObservationInput

class SessionAggregateSnapshotStoreTest {
    @Test
    fun persistsCanonicalAggregateAndReloadsByProofId() {
        val file = Files.createTempDirectory("aggregate-store").resolve("snapshots.json").toFile()
        val input = createAggregationObservationInput()
        assertTrue(addAggregationObservation(input, 0L, "peer-a", "device-a", false))
        val aggregate = aggregateObservationsForSession(input, windowsPerBand = 1)
        val id = UUID.randomUUID()
        SessionAggregateSnapshotStore(file).persist(id, aggregate)
        val reloaded = SessionAggregateSnapshotStore(file)
        assertEquals(aggregate.deviceCount, reloaded.snapshot(id)?.deviceCount)
        assertNull(reloaded.snapshot(UUID.randomUUID()))
    }
}

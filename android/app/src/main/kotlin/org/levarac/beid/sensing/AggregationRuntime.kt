package org.levarac.beid.sensing

import org.levarac.beid.shared.aggregation.AggregationObservationInput
import org.levarac.beid.shared.aggregation.SessionAggregate
import org.levarac.beid.shared.aggregation.addAggregationObservation
import org.levarac.beid.shared.aggregation.aggregateObservationsForSession
import org.levarac.beid.shared.aggregation.createAggregationObservationInput
import org.levarac.beid.shared.sensing.normalizedDisplayIdOrNull

/** Android's thin adapter over the shared observation aggregation API. */
internal class AggregationRuntime {
    private var input: AggregationObservationInput = createAggregationObservationInput()

    fun recordObservation(enin: Long, rpid: String, detectedDisplayId: String?): Boolean =
        addAggregationObservation(
            input = input,
            windowIndex = enin,
            peerKey = rpid,
            displayId = normalizedDisplayIdOrNull(detectedDisplayId),
            mutual = false,
        )

    val sessionAggregate: SessionAggregate
        get() = aggregateObservationsForSession(input = input, windowsPerBand = 1)

    fun reset() {
        input = createAggregationObservationInput()
    }
}

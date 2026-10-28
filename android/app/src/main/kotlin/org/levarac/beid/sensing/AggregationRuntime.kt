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
    private class Observation(val enin: Long, val rpid: String, val displayId: String?, val previous: Observation?)
    private var latest: Observation? = null

    fun recordObservation(enin: Long, rpid: String, detectedDisplayId: String?): Boolean {
        val displayId = normalizedDisplayIdOrNull(detectedDisplayId)
        val accepted = addAggregationObservation(
            input = input,
            windowIndex = enin,
            peerKey = rpid,
            displayId = displayId,
            mutual = false,
        )
        if (accepted) latest = Observation(enin, rpid, displayId, latest)
        return accepted
    }

    /** O(1) capture on main; replay and aggregation run only when the writer asks. */
    fun snapshotAggregate(): () -> SessionAggregate {
        val last = latest
        return {
            val captured = createAggregationObservationInput()
            generateSequence(last) { it.previous }.toList().asReversed().forEach {
                check(addAggregationObservation(captured, it.enin, it.rpid, it.displayId, false))
            }
            aggregateObservationsForSession(input = captured, windowsPerBand = 1)
        }
    }

    val sessionAggregate: SessionAggregate
        get() = aggregateObservationsForSession(input = input, windowsPerBand = 1)

    fun reset() {
        input = createAggregationObservationInput()
        latest = null
    }
}

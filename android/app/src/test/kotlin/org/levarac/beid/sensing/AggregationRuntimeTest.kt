package org.levarac.beid.sensing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.levarac.beid.shared.jointestsupport.aggregationParityExpectedDevices
import org.levarac.beid.shared.jointestsupport.aggregationParityExpectedMutualObservations
import org.levarac.beid.shared.jointestsupport.aggregationParityExpectedObservations
import org.levarac.beid.shared.jointestsupport.aggregationParityExpectedWindows
import org.levarac.beid.shared.jointestsupport.aggregationParityFixtureJson

class AggregationRuntimeTest {
    @Test
    fun checkedNativeParityFixtureMatchesExpectedAggregate() {
        val runtime = AggregationRuntime()
        Json.parseToJsonElement(aggregationParityFixtureJson()).jsonArray.forEach { row ->
            val value = row.jsonObject
            runtime.recordObservation(
                enin = value.getValue("windowIndex").jsonPrimitive.content.toLong(),
                rpid = value.getValue("peerKey").jsonPrimitive.content,
                detectedDisplayId = value["displayId"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content,
            )
        }
        val aggregate = runtime.sessionAggregate
        assertEquals(aggregationParityExpectedObservations(), aggregate.observationCount)
        assertEquals(aggregationParityExpectedWindows(), aggregate.windowCount)
        assertEquals(aggregationParityExpectedDevices(), aggregate.deviceCount)
        assertEquals(aggregationParityExpectedMutualObservations(), aggregate.mutualObservationCount)
    }
    @Test
    fun realDetectionFieldsProduceSharedSessionAggregate() {
        val runtime = AggregationRuntime()
        assertTrue(runtime.recordObservation(0L, "peer-a", "device-a"))
        assertTrue(runtime.recordObservation(1L, "peer-b", "device-a"))
        assertTrue(runtime.recordObservation(2L, "peer-c", null))
        val aggregate = runtime.sessionAggregate
        assertEquals(1, aggregate.deviceCount)
        assertEquals(3, aggregate.observationCount)
        assertEquals(1, aggregate.observationsWithoutDisplayIdCount)
        assertEquals(3, aggregate.windowCount)
        assertEquals(0, aggregate.mutualDeviceCount)
    }
}

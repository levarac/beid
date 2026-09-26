package org.levarac.beid.shared.support

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.long
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SupportBundleRecorderTest {
    @Test
    fun outputHasOnlyTheClosedSchemaAndEnumValues() {
        val recorder = SupportBundleRecorder()
        for (state in SupportState.entries) {
            for (failure in SupportFailure.entries) {
                recorder.record(state, failure, 3_600_123)
            }
        }
        for (platform in SupportPlatform.entries) {
            val json = Json.parseToJsonElement(recorder.exportJson(platform, "1.2.3", "42", "4242")).jsonObject
            assertEquals(setOf("schemaVersion", "platform", "appVersion", "build", "gitHeight", "historyScope", "entries"), json.keys)
            assertEquals(platform.name, json.getValue("platform").jsonPrimitive.content)
            assertEquals("current_process", json.getValue("historyScope").jsonPrimitive.content)
            val entries = json.getValue("entries").jsonArray
            assertTrue(entries.isNotEmpty())
            for (entry in entries) {
                val fields = entry.jsonObject
                assertEquals(setOf("hourStartEpochMs", "state", "failure"), fields.keys)
                assertTrue(fields.getValue("state").jsonPrimitive.content in SupportState.entries.map { it.name })
                assertTrue(fields.getValue("failure").jsonPrimitive.content in SupportFailure.entries.map { it.name })
            }
        }
    }

    @Test
    fun exportsVersionBuildAndOrderedTransitionsWithFailureReasons() {
        val recorder = SupportBundleRecorder()
        recorder.record(SupportState.SENSING, SupportFailure.NONE, 3_600_100)
        recorder.record(SupportState.JOIN_FAILED, SupportFailure.NETWORK_REQUIRED, 7_200_200)
        val json = Json.parseToJsonElement(recorder.exportJson(SupportPlatform.IOS, "1.2.3", "42", "4242")).jsonObject
        assertEquals("1", json.getValue("schemaVersion").jsonPrimitive.content)
        assertEquals("1.2.3", json.getValue("appVersion").jsonPrimitive.content)
        assertEquals("42", json.getValue("build").jsonPrimitive.content)
        assertEquals(4242L, json.getValue("gitHeight").jsonPrimitive.long)
        assertFalse(json.getValue("gitHeight").jsonPrimitive.isString)
        val entries = json.getValue("entries").jsonArray
        assertEquals(2, entries.size)
        assertEquals("SENSING", entries[0].jsonObject.getValue("state").jsonPrimitive.content)
        assertEquals("NETWORK_REQUIRED", entries[1].jsonObject.getValue("failure").jsonPrimitive.content)
        assertEquals("7200000", entries[1].jsonObject.getValue("hourStartEpochMs").jsonPrimitive.content)
    }

    @Test
    fun actualOutputRejectsSyntheticSecretsAndRawRpidValuesAtEveryStringInput() {
        val markers = listOf("synthetic-private-key-DO-NOT-EXPORT", "a1b2c3d4e5f60718293a4b5c6d7e8f90ab",
            "a1b2c3d4", "7e8f90ab", "obLD1OX2BxgpOktcbX6PkKs=",
            "f4adc8d6d9e25499cf15290fffecb8eeff25a7027854cd1adbe5138eba494c22",
            "ef93b80721fc4e29d8a37594303a251f6eaebe88b41bb29d17da1e905b5224af",
            "\"injected\":true", "network_required secret")
        for (marker in markers) {
            val recorder = SupportBundleRecorder()
            recorder.record(SupportState.JOIN_FAILED, supportFailureForReasonKey(marker), 123)
            val bytes = recorder.exportJson(SupportPlatform.ANDROID, marker, marker, marker).encodeToByteArray()
            val output = bytes.decodeToString()
            assertFalse(output.contains(marker))
            assertEquals("unknown", Json.parseToJsonElement(output).jsonObject.getValue("appVersion").jsonPrimitive.content)
            assertEquals(JsonNull, Json.parseToJsonElement(output).jsonObject.getValue("gitHeight"))
            assertTrue(output.contains("UNKNOWN"))
        }
    }

    @Test
    fun keepsOnlyLatestHundredChangesAndSuppressesRepeatedState() {
        val recorder = SupportBundleRecorder()
        repeat(120) { index ->
            val state = if (index % 2 == 0) SupportState.SENSING else SupportState.IDLE
            recorder.record(state, SupportFailure.NONE, index.toLong() * 3_600_000)
            recorder.record(state, SupportFailure.NONE, index.toLong() * 3_600_000)
        }
        val entries = Json.parseToJsonElement(recorder.exportJson(SupportPlatform.IOS, "1.0.0", "1", "1"))
            .jsonObject.getValue("entries").jsonArray
        assertEquals(100, entries.size)
        assertEquals("72000000", entries.first().jsonObject.getValue("hourStartEpochMs").jsonPrimitive.content)
        assertEquals("428400000", entries.last().jsonObject.getValue("hourStartEpochMs").jsonPrimitive.content)
    }

    @Test
    fun timestampsAreHourBucketsRatherThanExactSightingTimes() {
        val recorder = SupportBundleRecorder()
        recorder.record(SupportState.RECORDING, SupportFailure.NONE, 7_234_567)
        val entry = Json.parseToJsonElement(recorder.exportJson(SupportPlatform.IOS, "1.0.0", "1", "1"))
            .jsonObject.getValue("entries").jsonArray.single().jsonObject
        assertFalse(entry.containsKey("timestampMs"))
        assertEquals("7200000", entry.getValue("hourStartEpochMs").jsonPrimitive.content)
    }

    @Test
    fun onlyExactKnownReasonKeysAreAccepted() {
        assertEquals(SupportFailure.NETWORK_REQUIRED, supportFailureForReasonKey("network_required"))
        assertEquals(SupportFailure.UNKNOWN, supportFailureForReasonKey("network_required\nprivate-key"))
        assertEquals(SupportFailure.UNKNOWN, supportFailureForReasonKey("NETWORK_REQUIRED"))
    }

    @Test
    fun gitHeightIsABoundedDecimalNumberOrNull() {
        val recorder = SupportBundleRecorder()
        for (height in listOf("0", "1", "0042", "9999999999")) {
            val json = Json.parseToJsonElement(recorder.exportJson(SupportPlatform.ANDROID, "1", "1", height)).jsonObject
            assertEquals(height.toLong(), json.getValue("gitHeight").jsonPrimitive.long)
            assertFalse(json.getValue("gitHeight").jsonPrimitive.isString)
        }
        for (height in listOf("", "local", "-1", "+1", "1.2", "1e3", " 1", "1\n", "99999999999", "１２３")) {
            val json = Json.parseToJsonElement(recorder.exportJson(SupportPlatform.IOS, "1", "1", height)).jsonObject
            assertEquals(JsonNull, json.getValue("gitHeight"))
        }
    }
}

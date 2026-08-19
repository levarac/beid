package org.levarac.beid.sensing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ScanDeviceAccountingTest {

    @Test
    fun coPresenceCountsDistinctRpidsWithinTheSameWindow() {
        val accounting = ScanDeviceAccounting()
        accounting.record(enin = 1, rpid = "rpid-a", detectedDisplayId = null)
        accounting.record(enin = 1, rpid = "rpid-b", detectedDisplayId = null)
        accounting.record(enin = 1, rpid = "rpid-a", detectedDisplayId = null)

        assertEquals(2, accounting.coPresentDeviceCount)
    }

    @Test
    fun coPresenceClearsAtAWindowBoundaryBeforeCountingTheNewDetection() {
        val accounting = ScanDeviceAccounting()
        accounting.record(enin = 1, rpid = "rpid-a", detectedDisplayId = null)
        accounting.record(enin = 1, rpid = "rpid-b", detectedDisplayId = null)

        accounting.record(enin = 2, rpid = "rpid-a-rotated", detectedDisplayId = null)

        assertEquals(1, accounting.coPresentDeviceCount, "a lingering device's rotated rpid must not carry into the new window")
    }

    @Test
    fun distinctDeviceCountIsKeyedOnNormalizedDisplayIdAndExcludesNulls() {
        val accounting = ScanDeviceAccounting()

        val firstChanged = accounting.record(enin = 1, rpid = "rpid-a", detectedDisplayId = "ABCD")
        assertTrue(firstChanged)
        assertEquals(1, accounting.distinctDeviceCount)

        // Same device, different case and a rotated rpid: must not double-count.
        val duplicateChanged = accounting.record(enin = 2, rpid = "rpid-a-rotated", detectedDisplayId = "abcd")
        assertFalse(duplicateChanged)
        assertEquals(1, accounting.distinctDeviceCount)

        // No display id (Barnard B003 unavailable): excluded entirely, never falls back to rpid.
        val unidentifiedChanged = accounting.record(enin = 2, rpid = "rpid-c", detectedDisplayId = null)
        assertFalse(unidentifiedChanged)
        assertEquals(1, accounting.distinctDeviceCount)

        val secondDeviceChanged = accounting.record(enin = 2, rpid = "rpid-d", detectedDisplayId = "EF01")
        assertTrue(secondDeviceChanged)
        assertEquals(2, accounting.distinctDeviceCount)
    }

    @Test
    fun resetClearsBothCountersAndTheWindowBoundary() {
        val accounting = ScanDeviceAccounting()
        accounting.record(enin = 1, rpid = "rpid-a", detectedDisplayId = "ABCD")

        accounting.reset()

        assertEquals(0, accounting.coPresentDeviceCount)
        assertEquals(0, accounting.distinctDeviceCount)
        // Re-observing the same enin after a reset must still count fresh (no stale window boundary).
        accounting.record(enin = 1, rpid = "rpid-a", detectedDisplayId = "ABCD")
        assertEquals(1, accounting.coPresentDeviceCount)
    }
}

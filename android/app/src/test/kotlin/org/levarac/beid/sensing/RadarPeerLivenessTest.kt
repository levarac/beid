package org.levarac.beid.sensing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Display-only radar peer liveness, ported from iOS release/1.1.0
 * `SensingCoordinator.currentlyDetectedDisplayIDs(at:)`,
 * `isDetectedDeviceDimmed(_:at:)` and `rememberDetectedDevice(_:at:)`
 * (#855/#901). Boundaries are literal milliseconds, not the constants, so a
 * change to either duration turns a test red.
 */
class RadarPeerLivenessTest {
    private val heardAt = 1_764_000_000_000L

    @Test
    fun theDurationsAreIosValues() {
        assertEquals(300_000L, BeidConfig.detectedNowTimeoutMillis)
        assertEquals(30_000L, BeidConfig.detectedNowDimAfterMillis)
    }

    @Test
    fun aPeerStaysOnTheRadarUntilExactlyFiveMinutesOfSilence() {
        assertTrue(RadarPeerLiveness.isCurrent(heardAt, nowMillis = heardAt))
        assertTrue(RadarPeerLiveness.isCurrent(heardAt, nowMillis = heardAt + 299_999))
        assertFalse(RadarPeerLiveness.isCurrent(heardAt, nowMillis = heardAt + 300_000), "strict: 300 s is gone")
        assertFalse(RadarPeerLiveness.isCurrent(heardAt, nowMillis = heardAt + 300_001))
    }

    @Test
    fun aPeerNeverHeardIsNotOnTheRadar() {
        assertFalse(RadarPeerLiveness.isCurrent(null, nowMillis = heardAt))
    }

    @Test
    fun aPeerDimsFromExactlyThirtySecondsOfSilence() {
        assertFalse(RadarPeerLiveness.isDimmed(heardAt, nowMillis = heardAt))
        assertFalse(RadarPeerLiveness.isDimmed(heardAt, nowMillis = heardAt + 29_999))
        assertTrue(RadarPeerLiveness.isDimmed(heardAt, nowMillis = heardAt + 30_000), "inclusive: 30 s is dimmed")
        assertTrue(RadarPeerLiveness.isDimmed(heardAt, nowMillis = heardAt + 299_999))
    }

    @Test
    fun aPeerWithNoLastHeardIsDimmed() {
        assertTrue(RadarPeerLiveness.isDimmed(null, nowMillis = heardAt))
    }

    @Test
    fun lastHeardOnlyMovesForward() {
        val lastHeard = RadarPeerLastHeard()
        assertNull(lastHeard["d0000001"])
        lastHeard.remember("d0000001", heardAt + 5_000)
        lastHeard.remember("d0000001", heardAt)
        assertEquals(heardAt + 5_000, lastHeard["d0000001"], "a reordered older callback never moves it back")
        lastHeard.remember("d0000001", heardAt + 6_000)
        assertEquals(heardAt + 6_000, lastHeard["d0000001"])
        assertNull(lastHeard["d0000002"], "per id")
    }

    @Test
    fun clearingForgetsEveryPeer() {
        val lastHeard = RadarPeerLastHeard()
        lastHeard.remember("d0000001", heardAt)
        lastHeard.clear()
        assertNull(lastHeard["d0000001"])
    }
}

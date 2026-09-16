package org.levarac.beid.sensing

import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlinx.coroutines.test.runTest
import org.junit.Test
import org.levarac.beid.shared.clock.ClockPreflightState

/**
 * beid#464: the native adapter over the shared preflight. The decision itself
 * is covered in `shared/.../clock/ClockPreflightTest`; this proves the adapter
 * brackets the request with the injected clocks, feeds the header to shared,
 * reuses the cache, and turns a failed fetch into UNDETERMINABLE rather than
 * silence.
 */
class ClockPreflightControllerTest {
    private val serverDate = "Wed, 16 Sep 2026 11:58:53 GMT"
    private val serverMillis = 1_789_559_933_000L

    private class FakeClocks(var wall: Long, var monotonic: Long)

    private class FakeSource(var header: String?, var failure: Throwable? = null, val onFetch: () -> Unit = {}) :
        TrustedDateSource {
        var fetches = 0
        override suspend fun fetchDateHeader(): String? {
            fetches += 1
            onFetch()
            failure?.let { throw it }
            return header
        }
    }

    private fun controller(clocks: FakeClocks, source: TrustedDateSource, eninSeconds: Int = 300) =
        ClockPreflightController(
            source = source,
            wallMillis = { clocks.wall },
            monotonicMillis = { clocks.monotonic },
            eninSeconds = eninSeconds,
        )

    @Test
    fun stateIsNullBeforeTheFirstCheck() {
        val subject = controller(FakeClocks(serverMillis, 0L), FakeSource(serverDate))
        assertNull(subject.state.value)
    }

    @Test
    fun aMatchingServerDateIsWithinTolerance() = runTest {
        val clocks = FakeClocks(serverMillis, 1_000L)
        val subject = controller(clocks, FakeSource(serverDate) { clocks.monotonic += 300L })
        subject.check()
        assertEquals(ClockPreflightState.WITHIN_TOLERANCE, subject.state.value)
    }

    @Test
    fun aDeviceFortySecondsAheadIsOverTolerance() = runTest {
        val clocks = FakeClocks(serverMillis + 40_000L, 1_000L)
        val subject = controller(clocks, FakeSource(serverDate))
        subject.check()
        assertEquals(ClockPreflightState.OVER_TOLERANCE, subject.state.value)
    }

    @Test
    fun aMissingDateHeaderIsUndeterminable() = runTest {
        val subject = controller(FakeClocks(serverMillis, 1_000L), FakeSource(header = null))
        subject.check()
        assertEquals(ClockPreflightState.UNDETERMINABLE, subject.state.value)
    }

    @Test
    fun aFailedFetchIsUndeterminable() = runTest {
        val subject = controller(
            FakeClocks(serverMillis, 1_000L),
            FakeSource(header = serverDate, failure = java.io.IOException("offline")),
        )
        subject.check()
        assertEquals(ClockPreflightState.UNDETERMINABLE, subject.state.value)
    }

    @Test
    fun aRoundTripLongerThanTheToleranceIsUndeterminable() = runTest {
        val clocks = FakeClocks(serverMillis, 1_000L)
        // 31 s between request and response cannot place the offset inside ±30 s.
        val subject = controller(clocks, FakeSource(serverDate) { clocks.monotonic += 31_000L })
        subject.check()
        assertEquals(ClockPreflightState.UNDETERMINABLE, subject.state.value)
    }

    @Test
    fun aValidCacheIsReusedWithoutFetchingAgain() = runTest {
        val clocks = FakeClocks(serverMillis, 1_000L)
        val source = FakeSource(serverDate)
        val subject = controller(clocks, source)
        subject.check()
        clocks.wall += 60_000L
        clocks.monotonic += 60_000L
        subject.check()
        assertEquals(1, source.fetches)
        assertEquals(ClockPreflightState.WITHIN_TOLERANCE, subject.state.value)
    }

    @Test
    fun aCachedCheckStillSeesAManualClockChange() = runTest {
        val clocks = FakeClocks(serverMillis, 1_000L)
        val source = FakeSource(serverDate)
        val subject = controller(clocks, source)
        subject.check()
        clocks.wall += 120_000L
        subject.check()
        assertEquals(1, source.fetches)
        assertEquals(ClockPreflightState.OVER_TOLERANCE, subject.state.value)
    }

    @Test
    fun anExpiredCacheIsMeasuredAgain() = runTest {
        val clocks = FakeClocks(serverMillis, 1_000L)
        val source = FakeSource(serverDate)
        val subject = controller(clocks, source)
        subject.check()
        clocks.wall += 3_600_000L
        clocks.monotonic += 3_600_000L
        source.header = null
        subject.check()
        assertEquals(2, source.fetches)
        assertEquals(ClockPreflightState.UNDETERMINABLE, subject.state.value)
    }

    @Test
    fun aForcedCheckMeasuresEvenWithAValidCache() = runTest {
        val clocks = FakeClocks(serverMillis, 1_000L)
        val source = FakeSource(serverDate)
        val subject = controller(clocks, source)
        subject.check()
        subject.check(force = true)
        assertEquals(2, source.fetches)
    }

    @Test
    fun operatorOriginIsTakenFromAnHttpsTemplate() {
        assertEquals(
            "https://parallax-observation-operator.levarac.workers.dev/",
            operatorOriginOrNull("https://parallax-observation-operator.levarac.workers.dev/v1/events/by-code/{code}"),
        )
        assertEquals("https://example.test:8443/", operatorOriginOrNull("https://example.test:8443/a/{code}"))
    }

    @Test
    fun operatorOriginIsNullForBlankOrNonHttpsTemplates() {
        assertNull(operatorOriginOrNull(""))
        assertNull(operatorOriginOrNull("http://example.test/{code}"))
        assertNull(operatorOriginOrNull("not a url"))
    }
}

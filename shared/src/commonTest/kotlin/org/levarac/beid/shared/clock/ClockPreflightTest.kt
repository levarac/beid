package org.levarac.beid.shared.clock

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * beid#464. Every number here is a literal on purpose: comparing the
 * production policy against itself would stay green under any mutation of
 * the policy (see `EventConfirmThresholdTest` for the same reasoning).
 *
 * The injected clock is plain arguments — wall and monotonic milliseconds are
 * inputs to every shared call, so no test reads the host's clock.
 */
class ClockPreflightTest {

    // ---- policy: tolerance = eninSeconds / 10, validity = 12 × eninSeconds

    @Test
    fun toleranceIsOneTenthOfTheEninInMilliseconds() {
        assertEquals(30_000L, clockSkewToleranceMillis(300))
        assertEquals(60_000L, clockSkewToleranceMillis(600))
    }

    @Test
    fun toleranceIsDefinedAtBothClampBounds() {
        assertEquals(1_200L, clockSkewToleranceMillis(12))
        assertEquals(360_000L, clockSkewToleranceMillis(3_600))
    }

    @Test
    fun toleranceIsUndefinedJustOutsideTheClamp() {
        assertNull(clockSkewToleranceMillis(11))
        assertNull(clockSkewToleranceMillis(3_601))
        assertNull(clockSkewToleranceMillis(0))
        assertNull(clockSkewToleranceMillis(-300))
    }

    @Test
    fun validityIsTwelveEninsInMilliseconds() {
        assertEquals(3_600_000L, clockOffsetValidityMillis(300))
        assertEquals(144_000L, clockOffsetValidityMillis(12))
        assertEquals(43_200_000L, clockOffsetValidityMillis(3_600))
    }

    @Test
    fun validityIsUndefinedJustOutsideTheClamp() {
        assertNull(clockOffsetValidityMillis(11))
        assertNull(clockOffsetValidityMillis(3_601))
    }

    // ---- classification of an offset interval at eninSeconds = 300 (T = 30 000 ms)

    @Test
    fun intervalExactlyFillingTheToleranceIsWithin() {
        assertEquals(ClockPreflightState.WITHIN_TOLERANCE, classifyClockOffset(-30_000, 30_000, 300))
    }

    @Test
    fun intervalOneMillisecondPastTheUpperToleranceIsUndeterminable() {
        assertEquals(ClockPreflightState.UNDETERMINABLE, classifyClockOffset(0, 30_001, 300))
    }

    @Test
    fun intervalOneMillisecondPastTheLowerToleranceIsUndeterminable() {
        assertEquals(ClockPreflightState.UNDETERMINABLE, classifyClockOffset(-30_001, 0, 300))
    }

    @Test
    fun intervalStartingJustAboveTheToleranceIsOver() {
        assertEquals(ClockPreflightState.OVER_TOLERANCE, classifyClockOffset(30_001, 32_000, 300))
    }

    @Test
    fun intervalTouchingTheUpperToleranceIsUndeterminableNotOver() {
        assertEquals(ClockPreflightState.UNDETERMINABLE, classifyClockOffset(30_000, 32_000, 300))
    }

    @Test
    fun intervalEndingJustBelowTheNegativeToleranceIsOver() {
        assertEquals(ClockPreflightState.OVER_TOLERANCE, classifyClockOffset(-32_000, -30_001, 300))
    }

    @Test
    fun intervalTouchingTheNegativeToleranceIsUndeterminableNotOver() {
        assertEquals(ClockPreflightState.UNDETERMINABLE, classifyClockOffset(-32_000, -30_000, 300))
    }

    @Test
    fun intervalWiderThanTheWholeToleranceBandIsUndeterminable() {
        assertEquals(ClockPreflightState.UNDETERMINABLE, classifyClockOffset(-30_001, 30_001, 300))
    }

    @Test
    fun theSameOffsetIsJudgedAgainstTheGivenEninSeconds() {
        // 45 s of skew: over at 300 s ENINs (T = 30 s), within at 600 s ENINs (T = 60 s).
        assertEquals(ClockPreflightState.OVER_TOLERANCE, classifyClockOffset(45_000, 46_000, 300))
        assertEquals(ClockPreflightState.WITHIN_TOLERANCE, classifyClockOffset(45_000, 46_000, 600))
    }

    @Test
    fun atTheSmallestEninAFastSampleCanBeWithinButASlowOneCannot() {
        // T = 1 200 ms at eninSeconds = 12. A sample is [−1 000, round trip] for a
        // perfect clock: a 500 ms round trip fits, a 1 201 ms one crosses T.
        assertEquals(ClockPreflightState.WITHIN_TOLERANCE, classifyClockOffset(-1_000, 500, 12))
        assertEquals(ClockPreflightState.UNDETERMINABLE, classifyClockOffset(-1_000, 1_201, 12))
    }

    @Test
    fun outOfRangeEninSecondsIsUndeterminableEvenForAPerfectClock() {
        assertEquals(ClockPreflightState.UNDETERMINABLE, classifyClockOffset(0, 0, 11))
        assertEquals(ClockPreflightState.UNDETERMINABLE, classifyClockOffset(0, 0, 3_601))
    }

    @Test
    fun aPointIntervalIsWithin() {
        assertEquals(ClockPreflightState.WITHIN_TOLERANCE, classifyClockOffset(0, 0, 300))
    }

    @Test
    fun invertedIntervalIsUndeterminable() {
        assertEquals(ClockPreflightState.UNDETERMINABLE, classifyClockOffset(10, -10, 300))
    }

    // ---- HTTP Date (IMF-fixdate)

    @Test
    fun parsesImfFixdate() {
        // 2026-09-16T11:58:53Z
        assertEquals(1_789_559_933L, parseHttpDateEpochSeconds("Wed, 16 Sep 2026 11:58:53 GMT"))
        assertEquals(0L, parseHttpDateEpochSeconds("Thu, 01 Jan 1970 00:00:00 GMT"))
    }

    @Test
    fun parsesLeapDay() {
        // 2028-02-29T23:59:59Z
        assertEquals(1_835_481_599L, parseHttpDateEpochSeconds("Tue, 29 Feb 2028 23:59:59 GMT"))
    }

    @Test
    fun rejectsMissingOrMalformedDates() {
        assertNull(parseHttpDateEpochSeconds(null))
        assertNull(parseHttpDateEpochSeconds(""))
        assertNull(parseHttpDateEpochSeconds("Wed, 16 Sep 2026 11:58:53"))
        assertNull(parseHttpDateEpochSeconds("Wed, 16 Sep 2026 11:58:53 UTC"))
        assertNull(parseHttpDateEpochSeconds("Wed, 16 Foo 2026 11:58:53 GMT"))
        assertNull(parseHttpDateEpochSeconds("Wednesday, 16-Sep-26 11:58:53 GMT"))
        assertNull(parseHttpDateEpochSeconds("Wed Sep 16 11:58:53 2026"))
    }

    @Test
    fun rejectsOutOfRangeFields() {
        assertNull(parseHttpDateEpochSeconds("Wed, 16 Sep 2026 24:00:00 GMT"))
        assertNull(parseHttpDateEpochSeconds("Wed, 16 Sep 2026 11:60:00 GMT"))
        assertNull(parseHttpDateEpochSeconds("Wed, 16 Sep 2026 11:58:61 GMT"))
        assertNull(parseHttpDateEpochSeconds("Sat, 29 Feb 2025 00:00:00 GMT"))
        assertNull(parseHttpDateEpochSeconds("Mon, 31 Apr 2026 00:00:00 GMT"))
        assertNull(parseHttpDateEpochSeconds("Wed, 00 Sep 2026 00:00:00 GMT"))
    }

    // 期待値はパーサではなく python3 の calendar.timegm で求めた。

    @Test
    fun parsesDatesInMonthsWhereTheDayOfYearArithmeticDiffers() {
        // 3 月は month <= 2 の年繰り下げと月番号の付け替えの境目、7 月と 12 月は
        // (153 * mp + 2) / 5 の切り捨てが +2 に依存する月。
        assertEquals(1_773_567_000L, parseHttpDateEpochSeconds("Sun, 15 Mar 2026 09:30:00 GMT"))
        assertEquals(1_782_907_200L, parseHttpDateEpochSeconds("Wed, 01 Jul 2026 12:00:00 GMT"))
        assertEquals(1_798_761_599L, parseHttpDateEpochSeconds("Thu, 31 Dec 2026 23:59:59 GMT"))
    }

    @Test
    fun parsesCenturyDatesThatOnlyTheFourHundredYearRuleGetsRight() {
        // 2000 年は 400 で割り切れるのでうるう年。
        assertEquals(951_825_600L, parseHttpDateEpochSeconds("Tue, 29 Feb 2000 12:00:00 GMT"))
        // era の / 400 と、era 内の年数 yoe の / 100 が効く日付。
        assertEquals(951_868_800L, parseHttpDateEpochSeconds("Wed, 01 Mar 2000 00:00:00 GMT"))
        assertEquals(4_107_542_400L, parseHttpDateEpochSeconds("Mon, 01 Mar 2100 00:00:00 GMT"))
    }

    @Test
    fun rejectsLeapDaysInCenturiesThatAreNotLeapYears() {
        assertNull(parseHttpDateEpochSeconds("Thu, 29 Feb 1900 00:00:00 GMT"))
        assertNull(parseHttpDateEpochSeconds("Mon, 29 Feb 2100 00:00:00 GMT"))
    }

    @Test
    fun rejectsTheThirtiethOfFebruaryEvenInALeapYear() {
        assertNull(parseHttpDateEpochSeconds("Wed, 30 Feb 2028 00:00:00 GMT"))
    }

    @Test
    fun acceptsTheLastDayOfEveryThirtyDayMonthAndRejectsTheThirtyFirst() {
        assertEquals(1_782_777_600L, parseHttpDateEpochSeconds("Tue, 30 Jun 2026 00:00:00 GMT"))
        assertEquals(1_790_726_400L, parseHttpDateEpochSeconds("Wed, 30 Sep 2026 00:00:00 GMT"))
        assertEquals(1_795_996_800L, parseHttpDateEpochSeconds("Mon, 30 Nov 2026 00:00:00 GMT"))
        assertNull(parseHttpDateEpochSeconds("Wed, 31 Jun 2026 00:00:00 GMT"))
        assertNull(parseHttpDateEpochSeconds("Thu, 31 Sep 2026 00:00:00 GMT"))
        assertNull(parseHttpDateEpochSeconds("Tue, 31 Nov 2026 00:00:00 GMT"))
    }

    @Test
    fun acceptsTheThirtyFirstOfALongMonthAndRejectsTheThirtySecond() {
        assertEquals(1_785_456_000L, parseHttpDateEpochSeconds("Fri, 31 Jul 2026 00:00:00 GMT"))
        assertEquals(1_793_404_800L, parseHttpDateEpochSeconds("Sat, 31 Oct 2026 00:00:00 GMT"))
        assertNull(parseHttpDateEpochSeconds("Sun, 32 Jan 2026 00:00:00 GMT"))
        assertNull(parseHttpDateEpochSeconds("Fri, 32 Dec 2026 00:00:00 GMT"))
    }

    @Test
    fun aLeapSecondIsAcceptedAsTheFollowingSecond() {
        // 2025-12-31T23:59:60 は 2026-01-01T00:00:00 と同じ Unix 秒になる。
        assertEquals(1_767_225_600L, parseHttpDateEpochSeconds("Wed, 31 Dec 2025 23:59:60 GMT"))
    }

    // ---- sample: bracketed by the device clock at request time

    @Test
    fun sampleIntervalSpansTheDateSecondAndTheRoundTrip() {
        val sample = assertNotNull(
            clockOffsetSampleFromHttpDate(
                requestWallMillis = 1_789_559_933_000L,
                requestMonotonicMillis = 5_000L,
                responseMonotonicMillis = 5_400L,
                dateHeader = "Wed, 16 Sep 2026 11:58:53 GMT",
            ),
        )
        // The server said 11:58:53 at some instant in [53.000, 54.000); the device read
        // 53.000 at request start and at most 400 ms passed before the reply.
        assertEquals(-1_000L, sample.lowMillis)
        assertEquals(400L, sample.highMillis)
        assertEquals(1_789_559_933_000L, sample.wallAtMillis)
        assertEquals(5_000L, sample.monotonicAtMillis)
    }

    @Test
    fun aZeroRoundTripIsAValidSample() {
        val sample = assertNotNull(clockOffsetSampleFromHttpDate(0L, 10L, 10L, "Thu, 01 Jan 1970 00:00:00 GMT"))
        assertEquals(-1_000L, sample.lowMillis)
        assertEquals(0L, sample.highMillis)
    }

    @Test
    fun sampleWithoutAParsableDateIsNull() {
        assertNull(clockOffsetSampleFromHttpDate(0L, 0L, 10L, null))
        assertNull(clockOffsetSampleFromHttpDate(0L, 0L, 10L, "not a date"))
    }

    @Test
    fun sampleWhoseMonotonicClockRanBackwardsIsNull() {
        assertNull(clockOffsetSampleFromHttpDate(0L, 10L, 9L, "Thu, 01 Jan 1970 00:00:00 GMT"))
    }

    // ---- preflight: cache, validity, projection

    private val dateAtEpoch = "Wed, 16 Sep 2026 11:58:53 GMT"
    private val epochMillis = 1_789_559_933_000L

    /** Records a sample whose interval is [lo, hi] = [-1 000, 400] at eninSeconds 300. */
    private fun measuredPreflight(): ClockPreflight = ClockPreflight().apply {
        recordMeasurement(epochMillis, 5_000L, 5_400L, dateAtEpoch)
    }

    @Test
    fun beforeAnyMeasurementTheStateIsUndeterminable() {
        val preflight = ClockPreflight()
        assertEquals(ClockPreflightState.UNDETERMINABLE, preflight.state(epochMillis, 0L, 300))
        assertTrue(preflight.needsMeasurement(0L, 300))
    }

    @Test
    fun aGoodMeasurementIsWithinAndNeedsNoRemeasurement() {
        val preflight = measuredPreflight()
        assertEquals(ClockPreflightState.WITHIN_TOLERANCE, preflight.state(epochMillis, 5_000L, 300))
        assertFalse(preflight.needsMeasurement(5_000L, 300))
    }

    @Test
    fun aMeasurementFromASkewedDeviceIsOver() {
        val preflight = ClockPreflight()
        // Device reads 40 s ahead of the operator.
        preflight.recordMeasurement(epochMillis + 40_000L, 5_000L, 5_400L, dateAtEpoch)
        assertEquals(ClockPreflightState.OVER_TOLERANCE, preflight.state(epochMillis + 40_000L, 5_000L, 300))
    }

    @Test
    fun aFailedMeasurementIsUndeterminableAndStillNeedsMeasurement() {
        val preflight = ClockPreflight()
        preflight.recordMeasurement(epochMillis, 5_000L, 5_400L, null)
        assertEquals(ClockPreflightState.UNDETERMINABLE, preflight.state(epochMillis, 5_400L, 300))
        assertTrue(preflight.needsMeasurement(5_400L, 300))
    }

    @Test
    fun aFailedRemeasurementDiscardsTheEarlierGoodOne() {
        val preflight = measuredPreflight()
        preflight.recordMeasurement(epochMillis + 1_000L, 6_000L, 6_100L, "garbage")
        assertEquals(ClockPreflightState.UNDETERMINABLE, preflight.state(epochMillis + 1_000L, 6_100L, 300))
    }

    @Test
    fun theCachedOffsetIsValidOneMillisecondBeforeTwelveEnins() {
        val preflight = measuredPreflight()
        val elapsed = 3_600_000L - 1L
        assertFalse(preflight.needsMeasurement(5_000L + elapsed, 300))
        assertEquals(
            ClockPreflightState.WITHIN_TOLERANCE,
            preflight.state(epochMillis + elapsed, 5_000L + elapsed, 300),
        )
    }

    @Test
    fun theCachedOffsetExpiresAtExactlyTwelveEnins() {
        val preflight = measuredPreflight()
        val elapsed = 3_600_000L
        assertTrue(preflight.needsMeasurement(5_000L + elapsed, 300))
        assertEquals(
            ClockPreflightState.UNDETERMINABLE,
            preflight.state(epochMillis + elapsed, 5_000L + elapsed, 300),
        )
    }

    @Test
    fun validityFollowsTheEninSecondsAskedAbout() {
        val preflight = measuredPreflight()
        // 200 s later: still valid at 300 s ENINs (V = 3 600 s), expired at 12 s ENINs (V = 144 s).
        assertFalse(preflight.needsMeasurement(5_000L + 200_000L, 300))
        assertTrue(preflight.needsMeasurement(5_000L + 200_000L, 12))
    }

    @Test
    fun invalidEninSecondsAlwaysNeedsMeasurement() {
        val preflight = measuredPreflight()
        assertTrue(preflight.needsMeasurement(5_000L, 11))
    }

    @Test
    fun aMonotonicClockBehindTheSampleMeansARebootAndInvalidatesTheCache() {
        val preflight = measuredPreflight()
        assertTrue(preflight.needsMeasurement(4_999L, 300))
        assertEquals(ClockPreflightState.UNDETERMINABLE, preflight.state(epochMillis, 4_999L, 300))
    }

    @Test
    fun settingTheWallClockForwardAfterMeasuringIsOverWithoutRemeasuring() {
        val preflight = measuredPreflight()
        // One second of real time later the user sets the clock 60 s forward.
        assertEquals(
            ClockPreflightState.OVER_TOLERANCE,
            preflight.state(epochMillis + 61_000L, 5_000L + 1_000L, 300),
        )
    }

    @Test
    fun settingTheWallClockBackAfterMeasuringIsOverWithoutRemeasuring() {
        val preflight = measuredPreflight()
        assertEquals(
            ClockPreflightState.OVER_TOLERANCE,
            preflight.state(epochMillis - 59_000L, 5_000L + 1_000L, 300),
        )
    }

    @Test
    fun aWallClockJumpIsAddedToTheCachedInterval() {
        val preflight = ClockPreflight()
        // Interval [-1 000, 400] + a 29 600 ms forward jump = [28 600, 30 000] → still within.
        preflight.recordMeasurement(epochMillis, 5_000L, 5_400L, dateAtEpoch)
        assertEquals(
            ClockPreflightState.WITHIN_TOLERANCE,
            preflight.state(epochMillis + 29_600L, 5_000L, 300),
        )
        // One more millisecond of jump crosses T.
        assertEquals(
            ClockPreflightState.UNDETERMINABLE,
            preflight.state(epochMillis + 29_601L, 5_000L, 300),
        )
    }

    @Test
    fun driftAllowanceWidensTheCachedIntervalByOneMillisecondPerTenSeconds() {
        val preflight = ClockPreflight()
        // Interval [-1 000, 400] shifted to hi = 30 000 by a 29 600 ms jump, then 10 000 ms of
        // monotonic time pass: drift = ceil(10 000 / 10 000) = 1 → hi' = 30 001.
        preflight.recordMeasurement(epochMillis, 5_000L, 5_400L, dateAtEpoch)
        assertEquals(
            ClockPreflightState.UNDETERMINABLE,
            preflight.state(epochMillis + 29_600L + 10_000L, 5_000L + 10_000L, 300),
        )
    }

    @Test
    fun driftAllowanceRoundsUpSoTheFirstMillisecondAlreadyCounts() {
        val preflight = ClockPreflight()
        preflight.recordMeasurement(epochMillis, 5_000L, 5_400L, dateAtEpoch)
        assertEquals(
            ClockPreflightState.UNDETERMINABLE,
            preflight.state(epochMillis + 29_600L + 1L, 5_000L + 1L, 300),
        )
    }

    @Test
    fun driftAllowanceIsACeilingOfElapsedOverTenThousand() {
        val preflight = ClockPreflight()
        // hi = 400 + 29 599 = 29 999 before drift; 10 001 ms elapsed → drift 2 → 30 001.
        preflight.recordMeasurement(epochMillis, 5_000L, 5_400L, dateAtEpoch)
        assertEquals(
            ClockPreflightState.UNDETERMINABLE,
            preflight.state(epochMillis + 29_599L + 10_001L, 5_000L + 10_001L, 300),
        )
    }

    @Test
    fun driftAllowanceWidensTheLowSideDownwardsToo() {
        val preflight = measuredPreflight()
        // -29 000 ms の時計変更で [-1 000, 400] は [-30 000, -28 600]。下端はちょうど -T なので WITHIN。
        assertEquals(
            ClockPreflightState.WITHIN_TOLERANCE,
            preflight.state(epochMillis - 29_000L, 5_000L, 300),
        )
        // 10 000 ms 経つと drift 1 で下端は -30 001 になり、-T をまたぐので UNDETERMINABLE。
        // 下端に drift を足す向きだと -29 999 のまま WITHIN に残る。
        assertEquals(
            ClockPreflightState.UNDETERMINABLE,
            preflight.state(epochMillis - 29_000L + 10_000L, 5_000L + 10_000L, 300),
        )
    }

    // ---- Swift Export bridge

    @Test
    fun stateKeysAreFrozenWireNames() {
        assertEquals("withinTolerance", clockPreflightStateKey(ClockPreflightState.WITHIN_TOLERANCE))
        assertEquals("overTolerance", clockPreflightStateKey(ClockPreflightState.OVER_TOLERANCE))
        assertEquals("undeterminable", clockPreflightStateKey(ClockPreflightState.UNDETERMINABLE))
    }
}

package org.levarac.beid.shared.clock

/**
 * Device-clock preflight — beid#464, decided in
 * `docs/decisions/issue-464-clock-skew-preflight.md`.
 *
 * Spec 134 requires `validFromEnin <= currentEnin < relayExpiresAtEnin` and
 * fails closed when the clock cannot establish that. This file answers only
 * "is the device clock close enough to trusted time to derive `currentEnin`
 * from it", in one of three states. It does not redefine any window boundary
 * (levarac/barnard#180, #200) and does not check Observation ENINs
 * (levarac/parallax#54).
 *
 * Every number is a function of `eninSeconds`, the B004 deployment parameter
 * (clamped by Barnard to `12..3600`). A value outside that clamp is not a
 * deployment Barnard would run, so every derived value is undefined for it
 * and the state is [ClockPreflightState.UNDETERMINABLE].
 *
 * Effects stay native: the HTTPS request that yields the `Date` header and
 * the wall/monotonic clock readings are inputs. Monotonic readings must keep
 * counting while the device sleeps (Android `SystemClock.elapsedRealtime`,
 * iOS `CLOCK_MONOTONIC_RAW`); a clock that pauses in sleep would make every
 * wake look like a wall-clock jump.
 */
public enum class ClockPreflightState {
    /** The whole offset interval lies within ±tolerance. */
    WITHIN_TOLERANCE,

    /** The whole offset interval lies outside ±tolerance. */
    OVER_TOLERANCE,

    /**
     * Anything else: no valid measurement, an expired or invalidated cache, an
     * interval that straddles the tolerance, or an out-of-range `eninSeconds`.
     */
    UNDETERMINABLE,
}

/**
 * Frozen wire names for Swift, where an exported Kotlin enum loses `name`
 * and equality (same reason as `eventJoinFailureReasonKey`).
 */
public fun clockPreflightStateKey(state: ClockPreflightState): String = when (state) {
    ClockPreflightState.WITHIN_TOLERANCE -> "withinTolerance"
    ClockPreflightState.OVER_TOLERANCE -> "overTolerance"
    ClockPreflightState.UNDETERMINABLE -> "undeterminable"
}

private const val MIN_ENIN_SECONDS: Int = 12
private const val MAX_ENIN_SECONDS: Int = 3_600

/** Relay lifetime cap from spec 134, in ENINs. */
private const val VALIDITY_ENINS: Long = 12L

/** 100 ppm crystal allowance: one millisecond per this many elapsed milliseconds. */
private const val DRIFT_DIVISOR_MILLIS: Long = 10_000L

private fun eninSecondsInRange(eninSeconds: Int): Boolean =
    eninSeconds >= MIN_ENIN_SECONDS && eninSeconds <= MAX_ENIN_SECONDS

/**
 * Allowed skew: one tenth of an ENIN. A skew δ makes the device name the
 * neighbouring ENIN for δ seconds around each boundary, so this bounds that
 * share of every ENIN to 10% and keeps any ENIN-granular decision within one
 * ENIN of the truth. `null` outside the Barnard clamp.
 */
public fun clockSkewToleranceMillis(eninSeconds: Int): Long? =
    if (eninSecondsInRange(eninSeconds)) eninSeconds.toLong() * 100L else null

/**
 * How long a measured offset may be reused: twelve ENINs, spec 134's maximum
 * relay lifetime, so one measurement never vouches for longer than the
 * longest window it gates. `null` outside the Barnard clamp.
 */
public fun clockOffsetValidityMillis(eninSeconds: Int): Long? =
    if (eninSecondsInRange(eninSeconds)) eninSeconds.toLong() * 1_000L * VALIDITY_ENINS else null

/**
 * Classifies the offset interval `[lowMillis, highMillis]`, where offset means
 * device clock minus trusted time. Both ends are inclusive and the tolerance
 * band is closed, so an interval that merely touches the band's outer edge is
 * not "over": it cannot rule out an offset of exactly the tolerance.
 */
public fun classifyClockOffset(lowMillis: Long, highMillis: Long, eninSeconds: Int): ClockPreflightState {
    val tolerance = clockSkewToleranceMillis(eninSeconds) ?: return ClockPreflightState.UNDETERMINABLE
    if (lowMillis > highMillis) return ClockPreflightState.UNDETERMINABLE
    if (lowMillis >= -tolerance && highMillis <= tolerance) return ClockPreflightState.WITHIN_TOLERANCE
    if (lowMillis > tolerance || highMillis < -tolerance) return ClockPreflightState.OVER_TOLERANCE
    return ClockPreflightState.UNDETERMINABLE
}

/**
 * One measurement: the offset interval and the device clock readings it is
 * anchored to. [wallAtMillis]/[monotonicAtMillis] are the readings taken just
 * before the request, which later projections measure elapsed time from.
 */
public class ClockOffsetSample internal constructor(
    public val lowMillis: Long,
    public val highMillis: Long,
    public val wallAtMillis: Long,
    public val monotonicAtMillis: Long,
)

/**
 * Builds a sample from an HTTP `Date` header.
 *
 * The server stamped `D` at some true instant in `[D, D + 1 s)`. At that
 * instant the device wall clock read somewhere in
 * `[requestWall, requestWall + (responseMonotonic − requestMonotonic)]`.
 * The upper end deliberately uses monotonic elapsed time rather than a wall
 * reading taken after the response, so a wall-clock change during the
 * request cannot distort the interval.
 */
public fun clockOffsetSampleFromHttpDate(
    requestWallMillis: Long,
    requestMonotonicMillis: Long,
    responseMonotonicMillis: Long,
    dateHeader: String?,
): ClockOffsetSample? {
    val serverSeconds = parseHttpDateEpochSeconds(dateHeader) ?: return null
    val roundTrip = responseMonotonicMillis - requestMonotonicMillis
    if (roundTrip < 0L) return null
    val serverMillis = serverSeconds * 1_000L
    return ClockOffsetSample(
        lowMillis = requestWallMillis - serverMillis - 1_000L,
        highMillis = requestWallMillis + roundTrip - serverMillis,
        wallAtMillis = requestWallMillis,
        monotonicAtMillis = requestMonotonicMillis,
    )
}

/**
 * The cached preflight. Holds at most one sample; a failed measurement
 * replaces it with nothing, so a retry that fails never leaves an older
 * verdict on screen.
 */
public class ClockPreflight public constructor() {
    private var sample: ClockOffsetSample? = null

    public fun recordMeasurement(
        requestWallMillis: Long,
        requestMonotonicMillis: Long,
        responseMonotonicMillis: Long,
        dateHeader: String?,
    ) {
        sample = clockOffsetSampleFromHttpDate(
            requestWallMillis,
            requestMonotonicMillis,
            responseMonotonicMillis,
            dateHeader,
        )
    }

    /** True when there is no sample the given `eninSeconds` would still accept. */
    public fun needsMeasurement(nowMonotonicMillis: Long, eninSeconds: Int): Boolean =
        usableSample(nowMonotonicMillis, eninSeconds) == null

    /**
     * The state right now. The cached interval is shifted by how far the wall
     * clock moved beyond monotonic time since the sample (a manual clock change
     * shows up immediately) and widened by the drift allowance.
     */
    public fun state(nowWallMillis: Long, nowMonotonicMillis: Long, eninSeconds: Int): ClockPreflightState {
        val cached = usableSample(nowMonotonicMillis, eninSeconds) ?: return ClockPreflightState.UNDETERMINABLE
        val elapsedMonotonic = nowMonotonicMillis - cached.monotonicAtMillis
        val wallJump = (nowWallMillis - cached.wallAtMillis) - elapsedMonotonic
        val drift = (elapsedMonotonic + DRIFT_DIVISOR_MILLIS - 1L) / DRIFT_DIVISOR_MILLIS
        return classifyClockOffset(
            lowMillis = cached.lowMillis + wallJump - drift,
            highMillis = cached.highMillis + wallJump + drift,
            eninSeconds = eninSeconds,
        )
    }

    private fun usableSample(nowMonotonicMillis: Long, eninSeconds: Int): ClockOffsetSample? {
        val cached = sample ?: return null
        val validity = clockOffsetValidityMillis(eninSeconds) ?: return null
        val elapsed = nowMonotonicMillis - cached.monotonicAtMillis
        // A monotonic reading behind the sample means the clock restarted (reboot).
        if (elapsed < 0L) return null
        if (elapsed >= validity) return null
        return cached
    }
}

private val MONTHS = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
private val DAY_NAMES = setOf("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")

/**
 * Parses an RFC 9110 IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`) to Unix
 * seconds. The obsolete RFC 850 and asctime forms are rejected rather than
 * guessed at: an unparsable header is a failed measurement, which the
 * preflight reports as undeterminable.
 */
public fun parseHttpDateEpochSeconds(value: String?): Long? {
    if (value == null || value.length != 29) return null
    if (value.substring(0, 3) !in DAY_NAMES) return null
    if (value[3] != ',' || value[4] != ' ' || value[7] != ' ' || value[11] != ' ' || value[16] != ' ') return null
    if (value[19] != ':' || value[22] != ':' || value[25] != ' ') return null
    if (value.substring(26) != "GMT") return null
    val day = value.digits(5, 7) ?: return null
    val month = MONTHS.indexOf(value.substring(8, 11)) + 1
    if (month == 0) return null
    val year = value.digits(12, 16) ?: return null
    val hour = value.digits(17, 19) ?: return null
    val minute = value.digits(20, 22) ?: return null
    val second = value.digits(23, 25) ?: return null
    if (day < 1 || day > daysInMonth(year, month)) return null
    if (hour > 23 || minute > 59 || second > 60) return null
    val days = daysFromCivil(year.toLong(), month, day)
    return days * 86_400L + hour * 3_600L + minute * 60L + second
}

private fun String.digits(start: Int, end: Int): Int? {
    var result = 0
    for (index in start until end) {
        val c = this[index]
        if (c < '0' || c > '9') return null
        result = result * 10 + (c - '0')
    }
    return result
}

private fun daysInMonth(year: Int, month: Int): Int = when (month) {
    2 -> if ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0) 29 else 28
    4, 6, 9, 11 -> 30
    else -> 31
}

/** Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm). */
private fun daysFromCivil(year: Long, month: Int, day: Int): Long {
    val y = if (month <= 2) year - 1 else year
    val era = (if (y >= 0) y else y - 399) / 400
    val yoe = y - era * 400
    val mp = if (month > 2) month - 3 else month + 9
    val doy = (153 * mp + 2) / 5 + day - 1
    val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
}

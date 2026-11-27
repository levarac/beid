package org.levarac.beid.sensing

import org.levarac.beid.shared.sensing.defaultEventConfirmThreshold

/**
 * Android-native mirror of iOS's `BeidConfig.eventConfirmThreshold`
 * (`ios/Beid/Models/BeidConfig.swift`). Both now read the same shared
 * constant (beid#231 item 3) — see
 * [org.levarac.beid.shared.sensing.defaultEventConfirmThreshold] for the
 * value's provenance and what it does not settle. Android has no
 * DEBUG/testing override of this value; that gap is accepted and out of
 * scope for #231 (see DECISIONS 2026-08-28).
 *
 * A plain `val`, not `const val`: this is a live read of the shared
 * constant, not a locally re-declared copy of its value, and a `val` makes
 * that unambiguous to a reader — a `const val` here would look identical to
 * the pre-#231 hardcoded duplicate this change removes.
 */
object BeidConfig {
    val eventConfirmThreshold: Int = defaultEventConfirmThreshold

    // Radar node signal strength (beid#722, porting iOS beid#652). Display
    // only: these shape a radius on screen and decide nothing. The values are
    // iOS's `BeidConfig.nodeSignal*`, which iOS marks UNVERIFIED ON HARDWARE;
    // they are copied, not re-chosen, so both radars move alike until a
    // device-lab measurement (beid#588) settles them for both.

    /** EMA weight per usable sample: `new = previous + alpha * (sample - previous)`. */
    const val nodeSignalSmoothingFactor: Double = 0.25

    /** Floor between radar republishes, measured on Barnard event timestamps, never a clock. */
    const val nodeSignalRedrawMinimumIntervalMillis: Long = 500

    /**
     * Exclusive upper bound for a usable RSSI sample. `0` is Barnard's
     * no-measurement sentinel and `127` the platform's unavailable marker;
     * accepting either would draw an unmeasured node at the radar's centre.
     */
    const val nodeSignalUsableUpperBoundDbm: Int = 0

    // Radar peer liveness (iOS release/1.1.0 `detectedNowTimeout` /
    // `detectedNowDimAfter`, #855/#901). Display only: the radar re-evaluates
    // them once per second from a wall clock. Recording, windows, the ledger,
    // presence and signatures never read them. Copied from iOS, which marks
    // both provisional until measured with locked iOS and Android peers.

    /** A peer leaves the radar once it has been silent this long (strict `<` keeps it). */
    const val detectedNowTimeoutMillis: Long = 300_000

    /** A retained peer is dimmed once it has been silent this long (inclusive). */
    const val detectedNowDimAfterMillis: Long = 30_000
}

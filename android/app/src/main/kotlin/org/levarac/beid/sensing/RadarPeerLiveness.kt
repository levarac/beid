package org.levarac.beid.sensing

/**
 * Display-only radar peer liveness, a port of iOS release/1.1.0
 * `SensingCoordinator.currentlyDetectedDisplayIDs(at:)` and
 * `isDetectedDeviceDimmed(_:at:)` (#855/#901).
 *
 * Both rules compare a peer's last-heard time with a wall-clock "now" in
 * epoch milliseconds. Barnard stamps detections and RSSI updates with
 * `System.currentTimeMillis()`, so both sides share one base.
 *
 * Nothing on the recording path reads this: windows, the session aggregate,
 * the ledger, Sigil presence and signed records keep every earlier sighting.
 */
object RadarPeerLiveness {
    /** On the radar while silent for less than [BeidConfig.detectedNowTimeoutMillis]; never without a last-heard time. */
    fun isCurrent(lastHeardAtMillis: Long?, nowMillis: Long): Boolean =
        lastHeardAtMillis != null && nowMillis - lastHeardAtMillis < BeidConfig.detectedNowTimeoutMillis

    /** Dimmed once silent for at least [BeidConfig.detectedNowDimAfterMillis], and whenever it has no last-heard time. */
    fun isDimmed(lastHeardAtMillis: Long?, nowMillis: Long): Boolean =
        lastHeardAtMillis == null || nowMillis - lastHeardAtMillis >= BeidConfig.detectedNowDimAfterMillis
}

/**
 * When each detected peer was last heard, keyed by normalized display id
 * (iOS `detectedLastHeardAt`). Display only, in memory only, per session.
 */
class RadarPeerLastHeard {
    private val lastHeardAtMillis = HashMap<String, Long>()

    /** iOS `rememberDetectedDevice`: monotonic, so a reordered older callback never expires a peer early. */
    fun remember(displayId: String, atMillis: Long) {
        lastHeardAtMillis[displayId] = maxOf(lastHeardAtMillis[displayId] ?: atMillis, atMillis)
    }

    operator fun get(displayId: String): Long? = lastHeardAtMillis[displayId]

    fun clear() = lastHeardAtMillis.clear()
}

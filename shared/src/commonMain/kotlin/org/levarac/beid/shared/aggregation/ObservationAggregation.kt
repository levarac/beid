package org.levarac.beid.shared.aggregation

internal const val MAX_AGGREGATION_OBSERVATION_COUNT = 100_000
internal const val MAX_AGGREGATION_TEXT_FIELD_BYTES = 4 * 1024

internal class AggregationObservation(
    val windowIndex: Long,
    val peerKey: String,
    val displayId: String?,
    val mutual: Boolean,
)

/**
 * Opaque accumulator for the observations a native caller has collected.
 *
 * The collection stays hidden so the exported boundary remains flat, final and
 * concrete. Callers add one observation at a time and read results back through
 * count / index accessors.
 */
public class AggregationObservationInput internal constructor(
    internal val observations: MutableList<AggregationObservation> = mutableListOf(),
) {
    public val observationCount: Int
        get() = observations.size
}

/**
 * Per-window aggregate.
 *
 * `peerCount` is a distinct count of the per-window peer key. That key does not
 * rotate inside a window, so counting it here is correct, and it also counts
 * peers that never yielded a display id. Never sum this across windows: a peer
 * present in two windows is counted once in each, and the total is not a device
 * count.
 *
 * Every number is reported at two scopes: over all observations, and over the
 * observations the caller flagged as mutual. Mutuality is not determinable
 * on-device today, so the mutual numbers may legitimately be zero for a whole
 * session while the all-observation numbers are not.
 *
 * A window row and a band row answer different questions, and even at a band
 * width of one window they can legitimately disagree: a peer with no display id
 * counts in this window's `peerCount` but not in that band's `deviceCount`.
 * That disagreement is intentional and must not be "fixed".
 *
 * This tier deliberately has no display-id-derived device count and no
 * `observationsWithoutDisplayIdCount`. Inside a window the per-window key does
 * not rotate, so `peerCount` already is that window's device count; adding a
 * second, display-id-derived one here would produce two device counts that
 * disagree for a reason no consumer could infer. The coverage question that
 * `observationsWithoutDisplayIdCount` answers on a band does not arise here
 * either, because no number at this tier depends on the display id. Adding one
 * is a contract change, not a patch.
 */
public class WindowAggregate internal constructor(
    public val windowIndex: Long,
    public val peerCount: Int,
    public val observationCount: Int,
    public val mutualPeerCount: Int,
    public val mutualObservationCount: Int,
)

/** Sparse ascending window series. A missing window means "nothing recorded". */
public class WindowAggregates internal constructor(
    internal val windows: List<WindowAggregate>,
) {
    public val windowCount: Int
        get() = windows.size

    public fun windowAt(index: Int): WindowAggregate? = windows.getOrNull(index)
}

/**
 * Per-band aggregate.
 *
 * A band spans whole windows, never a duration: the ENIN window length is a
 * runtime parameter (default 300 seconds, clamped to 12-3600), so this API
 * never accepts a seconds value and a band must not assume one.
 *
 * Because a band wider than one window is a cross-window question, its peer
 * total is `deviceCount`, derived from the stable per-event display id, not a
 * distinct count of the rotating per-window key. Counting the rotating key
 * across windows yields (device x window) and inflates with dwell time.
 *
 * `observationsWithoutDisplayIdCount` reports the observations that carried no
 * display id. They are never folded into `deviceCount`; they are surfaced so a
 * caller can judge how much of the band that count covers.
 *
 * A band row and a window row answer different questions, and even at a width
 * of one window they can legitimately disagree: a peer with no display id
 * counts in that window's `peerCount` but not in this band's `deviceCount`.
 * That disagreement is intentional and must not be "fixed".
 *
 * `deviceCount` and `mutualDeviceCount` are lower bounds, not exact figures.
 * The display id is 4 bytes, so two devices that happen to share one are
 * counted as a single device. At event scale that is unlikely, but it is not
 * impossible, and nothing here detects or defends against it. Do not present
 * either number as an exact device total.
 */
public class BandAggregate internal constructor(
    public val bandIndex: Long,
    public val windowsPerBand: Int,
    public val deviceCount: Int,
    public val observationCount: Int,
    public val observationsWithoutDisplayIdCount: Int,
    public val mutualDeviceCount: Int,
    public val mutualObservationCount: Int,
    public val mutualObservationsWithoutDisplayIdCount: Int,
)

/** Sparse ascending band series. A missing band means "nothing recorded". */
public class BandAggregates internal constructor(
    internal val bands: List<BandAggregate>,
    public val isSuccess: Boolean,
    public val errorCode: String?,
) {
    public val bandCount: Int
        get() = bands.size

    public fun bandAt(index: Int): BandAggregate? = bands.getOrNull(index)
}

/**
 * Whole-session aggregate, carrying both series plus the session totals.
 *
 * `deviceCount` is cross-window and therefore display-id derived, with the
 * display-id-less observations reported separately for the same reason as on a
 * band. Both scopes are present here too.
 *
 * `deviceCount` and `mutualDeviceCount` are lower bounds, not exact figures.
 * The display id is 4 bytes, so two devices that happen to share one are
 * counted as a single device. At event scale that is unlikely, but it is not
 * impossible, and nothing here detects or defends against it. Do not present
 * either number as an exact device total.
 */
public class SessionAggregate internal constructor(
    internal val windows: List<WindowAggregate>,
    internal val bands: List<BandAggregate>,
    public val isSuccess: Boolean,
    public val errorCode: String?,
    public val deviceCount: Int,
    public val observationCount: Int,
    public val observationsWithoutDisplayIdCount: Int,
    public val mutualDeviceCount: Int,
    public val mutualObservationCount: Int,
    public val mutualObservationsWithoutDisplayIdCount: Int,
) {
    public val windowCount: Int
        get() = windows.size

    public fun windowAt(index: Int): WindowAggregate? = windows.getOrNull(index)

    public val bandCount: Int
        get() = bands.size

    public fun bandAt(index: Int): BandAggregate? = bands.getOrNull(index)
}

public fun createAggregationObservationInput(): AggregationObservationInput =
    AggregationObservationInput()

/**
 * Adds one observation, checking null / length / shape only.
 *
 * Returns false when the observation is rejected at the boundary. `displayId`
 * is optional and opaque: its encoding is a native concern, so only presence
 * and size are checked here. Mutuality is decided by the caller and is never
 * inferred. Repeated identical detections are separate observations and are
 * not deduplicated.
 */
public fun addAggregationObservation(
    input: AggregationObservationInput,
    windowIndex: Long,
    peerKey: String,
    displayId: String?,
    mutual: Boolean,
): Boolean {
    if (windowIndex < 0L) {
        return false
    }
    if (!peerKey.isValidAggregationTextField()) {
        return false
    }
    if (displayId != null && !displayId.isValidAggregationTextField()) {
        return false
    }
    if (input.observations.size >= MAX_AGGREGATION_OBSERVATION_COUNT) {
        return false
    }

    input.observations += AggregationObservation(
        windowIndex = windowIndex,
        peerKey = peerKey,
        displayId = displayId,
        mutual = mutual,
    )
    return true
}

/** Groups observations by ENIN window. Windows without data are absent. */
public fun aggregateObservationsByWindow(
    input: AggregationObservationInput,
): WindowAggregates {
    val byWindow = input.observations.groupBy { it.windowIndex }
    val keys = byWindow.keys.sorted()
    return WindowAggregates(
        windows = keys.map { windowIndex ->
            val rows = byWindow.getValue(windowIndex)
            val mutualRows = rows.filter { it.mutual }
            WindowAggregate(
                windowIndex = windowIndex,
                peerCount = rows.distinctPeerKeyCount(),
                observationCount = rows.size,
                mutualPeerCount = mutualRows.distinctPeerKeyCount(),
                mutualObservationCount = mutualRows.size,
            )
        },
    )
}

/**
 * Groups observations into bands of [windowsPerBand] whole windows.
 *
 * Bands are anchored at absolute ENIN 0, not at the session's first window, so
 * a band index does not shift when an earlier observation is added. Bands
 * without data are absent; an invalid width is reported as an error rather
 * than as an empty series, because an empty series legitimately means
 * "no data".
 */
public fun aggregateObservationsByBand(
    input: AggregationObservationInput,
    windowsPerBand: Int,
): BandAggregates {
    if (windowsPerBand < 1) {
        return BandAggregates(
            bands = emptyList(),
            isSuccess = false,
            errorCode = "invalid_windows_per_band",
        )
    }

    val byBand = input.observations.groupBy { it.windowIndex / windowsPerBand }
    val keys = byBand.keys.sorted()
    return BandAggregates(
        bands = keys.map { bandIndex ->
            val rows = byBand.getValue(bandIndex)
            val mutualRows = rows.filter { it.mutual }
            BandAggregate(
                bandIndex = bandIndex,
                windowsPerBand = windowsPerBand,
                deviceCount = rows.distinctDisplayIdCount(),
                observationCount = rows.size,
                observationsWithoutDisplayIdCount = rows.withoutDisplayIdCount(),
                mutualDeviceCount = mutualRows.distinctDisplayIdCount(),
                mutualObservationCount = mutualRows.size,
                mutualObservationsWithoutDisplayIdCount = mutualRows.withoutDisplayIdCount(),
            )
        },
        isSuccess = true,
        errorCode = null,
    )
}

/**
 * Whole-session totals plus both series, built from the two functions above.
 *
 * This function has one failure mode, and it fails whole. An invalid
 * [windowsPerBand] returns `isSuccess` false with the band function's error
 * code, every count zero, and BOTH series empty — including the window series,
 * whose contents never depended on the band width. That is deliberate: a
 * partially populated result carrying a failure flag is the shape callers
 * misread. A caller that wants the per-window results despite a bad width can
 * call [aggregateObservationsByWindow] directly, which takes no width and
 * therefore cannot fail.
 */
public fun aggregateObservationsForSession(
    input: AggregationObservationInput,
    windowsPerBand: Int,
): SessionAggregate {
    val bands = aggregateObservationsByBand(input, windowsPerBand)
    if (!bands.isSuccess) {
        return SessionAggregate(
            windows = emptyList(),
            bands = emptyList(),
            isSuccess = false,
            errorCode = bands.errorCode,
            deviceCount = 0,
            observationCount = 0,
            observationsWithoutDisplayIdCount = 0,
            mutualDeviceCount = 0,
            mutualObservationCount = 0,
            mutualObservationsWithoutDisplayIdCount = 0,
        )
    }

    val rows = input.observations
    val mutualRows = rows.filter { it.mutual }
    return SessionAggregate(
        windows = aggregateObservationsByWindow(input).windows,
        bands = bands.bands,
        isSuccess = true,
        errorCode = null,
        deviceCount = rows.distinctDisplayIdCount(),
        observationCount = rows.size,
        observationsWithoutDisplayIdCount = rows.withoutDisplayIdCount(),
        mutualDeviceCount = mutualRows.distinctDisplayIdCount(),
        mutualObservationCount = mutualRows.size,
        mutualObservationsWithoutDisplayIdCount = mutualRows.withoutDisplayIdCount(),
    )
}

private fun List<AggregationObservation>.distinctPeerKeyCount(): Int {
    val keys = HashSet<String>()
    forEach { keys += it.peerKey }
    return keys.size
}

private fun List<AggregationObservation>.distinctDisplayIdCount(): Int {
    val ids = HashSet<String>()
    forEach { observation -> observation.displayId?.let { ids += it } }
    return ids.size
}

private fun List<AggregationObservation>.withoutDisplayIdCount(): Int =
    count { it.displayId == null }

private fun String.isValidAggregationTextField(): Boolean {
    if (isEmpty()) {
        return false
    }
    return try {
        encodeToByteArray(throwOnInvalidSequence = true).size <= MAX_AGGREGATION_TEXT_FIELD_BYTES
    } catch (_: Exception) {
        false
    }
}

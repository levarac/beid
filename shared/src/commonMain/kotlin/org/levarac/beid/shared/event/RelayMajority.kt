package org.levarac.beid.shared.event

public class RelayMajorityParameters internal constructor(
    public val recentWindowCount: Int,
    public val minimumLeadingRelayCount: Int,
    public val minimumLeadPercent: Int,
)

public class RelayObservationInput internal constructor(
    internal val counts: MutableMap<String, MutableMap<Long, Int>> = mutableMapOf(),
) {
    public val eventCount: Int
        get() = counts.size
}

public class RelayMajorityVerdict internal constructor(
    public val isSuccess: Boolean,
    public val errorCode: String?,
    public val isMajorityClear: Boolean,
    public val leadingEventCodeHashHex: String?,
    public val leadingRelayCount: Int,
    public val runnerUpRelayCount: Int,
)

public fun createRelayMajorityParameters(
    recentWindowCount: Int,
    minimumLeadingRelayCount: Int,
    minimumLeadPercent: Int,
): RelayMajorityParameters? {
    if (recentWindowCount < 1 || minimumLeadingRelayCount < 1 || minimumLeadPercent < 100) {
        return null
    }
    return RelayMajorityParameters(
        recentWindowCount = recentWindowCount,
        minimumLeadingRelayCount = minimumLeadingRelayCount,
        minimumLeadPercent = minimumLeadPercent,
    )
}

public fun defaultRelayMajorityParameters(): RelayMajorityParameters =
    RelayMajorityParameters(
        recentWindowCount = 3,
        minimumLeadingRelayCount = 3,
        minimumLeadPercent = 200,
    )

public fun createRelayObservationInput(): RelayObservationInput = RelayObservationInput()

public fun addRelayObservation(
    input: RelayObservationInput,
    eventCodeHashHex: String,
    windowIndex: Long,
    relayCount: Int,
): Boolean {
    if (windowIndex < 0L || relayCount < 0) {
        return false
    }
    if (eventCodeHashHex.length != EVENT_CODE_HASH_HEX_LENGTH) {
        return false
    }
    val key = eventCodeHashHex.lowercase()
    if (!key.all { it in '0'..'9' || it in 'a'..'f' }) {
        return false
    }
    val perWindow = input.counts.getOrPut(key) { mutableMapOf() }
    val existing = perWindow[windowIndex]
    if (existing == null || relayCount > existing) {
        perWindow[windowIndex] = relayCount
    }
    return true
}

// RED STEP — deliberately wrong implementation. It sums the recent windows
// instead of taking their maximum, and it calls a majority clear whenever the
// leader is merely ahead, ignoring both the floor and the lead percentage.
// Replaced once the vectors have been proven to fail against it.
public fun evaluateRelayMajority(
    input: RelayObservationInput,
    parameters: RelayMajorityParameters,
    atWindowIndex: Long,
): RelayMajorityVerdict {
    if (atWindowIndex < 0L) {
        return RelayMajorityVerdict(
            isSuccess = false,
            errorCode = "invalid_window_index",
            isMajorityClear = false,
            leadingEventCodeHashHex = null,
            leadingRelayCount = 0,
            runnerUpRelayCount = 0,
        )
    }

    val lowestWindow = atWindowIndex - parameters.recentWindowCount + 1
    val scored = input.counts.entries
        .map { (key, perWindow) ->
            key to perWindow.entries
                .filter { it.key in lowestWindow..atWindowIndex }
                .sumOf { it.value }
        }
        .sortedWith(compareByDescending<Pair<String, Int>> { it.second }.thenBy { it.first })

    val leading = scored.firstOrNull()
    val runnerUp = scored.getOrNull(1)
    val leadingCount = leading?.second ?: 0
    val runnerUpCount = runnerUp?.second ?: 0

    return RelayMajorityVerdict(
        isSuccess = true,
        errorCode = null,
        isMajorityClear = leadingCount > runnerUpCount,
        leadingEventCodeHashHex = leading?.first,
        leadingRelayCount = leadingCount,
        runnerUpRelayCount = runnerUpCount,
    )
}

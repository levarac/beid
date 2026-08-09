package org.levarac.beid.shared.aggregation

private const val SNAPSHOT_HEADER = "beid-session-aggregate-snapshot\t1"
internal const val MAX_SESSION_AGGREGATE_SNAPSHOT_BYTES = 8 * 1024 * 1024

/**
 * Result of encoding one finished session's [SessionAggregate] to its portable
 * snapshot text.
 */
public class SessionAggregateSnapshotEncodeResult internal constructor(
    public val isSuccess: Boolean,
    public val snapshotText: String?,
    public val errorCode: String?,
)

/** Result of decoding a portable snapshot text back into a [SessionAggregate]. */
public class SessionAggregateSnapshotLoadResult internal constructor(
    public val aggregate: SessionAggregate?,
    public val isSuccess: Boolean,
    public val errorCode: String?,
)

/**
 * Returns the canonical UTF-8 snapshot text that native storage must persist
 * atomically for one finished session's aggregate.
 *
 * Only a successful [SessionAggregate] can be encoded. `aggregateObservationsForSession`'s
 * one failure mode (an invalid `windowsPerBand`) has nothing meaningful to persist — a
 * caller must resolve that before session end, not carry a failed aggregate into storage.
 *
 * The snapshot is a value, not a ledger: unlike the unsent-window ledger snapshot this
 * format is modeled on, there is no revision counter here, because a session aggregate
 * never changes after the session it describes has ended.
 */
public fun encodeSessionAggregateSnapshot(
    aggregate: SessionAggregate,
): SessionAggregateSnapshotEncodeResult {
    if (!aggregate.isSuccess) {
        return SessionAggregateSnapshotEncodeResult(
            isSuccess = false,
            snapshotText = null,
            errorCode = "aggregate_not_successful",
        )
    }

    val text = buildString {
        append(SNAPSHOT_HEADER).append('\n')
        append("device-count\t").append(aggregate.deviceCount).append('\n')
        append("observation-count\t").append(aggregate.observationCount).append('\n')
        append("observations-without-display-id-count\t")
            .append(aggregate.observationsWithoutDisplayIdCount).append('\n')
        append("mutual-device-count\t").append(aggregate.mutualDeviceCount).append('\n')
        append("mutual-observation-count\t").append(aggregate.mutualObservationCount).append('\n')
        append("mutual-observations-without-display-id-count\t")
            .append(aggregate.mutualObservationsWithoutDisplayIdCount).append('\n')
        append("windows\t").append(aggregate.windowCount).append('\n')
        for (index in 0 until aggregate.windowCount) {
            val window = requireNotNull(aggregate.windowAt(index))
            append("window\t")
                .append(window.windowIndex).append('\t')
                .append(window.peerCount).append('\t')
                .append(window.observationCount).append('\t')
                .append(window.mutualPeerCount).append('\t')
                .append(window.mutualObservationCount).append('\n')
        }
        append("bands\t").append(aggregate.bandCount).append('\n')
        for (index in 0 until aggregate.bandCount) {
            val band = requireNotNull(aggregate.bandAt(index))
            append("band\t")
                .append(band.bandIndex).append('\t')
                .append(band.windowsPerBand).append('\t')
                .append(band.deviceCount).append('\t')
                .append(band.observationCount).append('\t')
                .append(band.observationsWithoutDisplayIdCount).append('\t')
                .append(band.mutualDeviceCount).append('\t')
                .append(band.mutualObservationCount).append('\t')
                .append(band.mutualObservationsWithoutDisplayIdCount).append('\n')
        }
        append("end\n")
    }

    if (text.encodeToByteArray().size > MAX_SESSION_AGGREGATE_SNAPSHOT_BYTES) {
        return SessionAggregateSnapshotEncodeResult(
            isSuccess = false,
            snapshotText = null,
            errorCode = "snapshot_too_large",
        )
    }

    return SessionAggregateSnapshotEncodeResult(
        isSuccess = true,
        snapshotText = text,
        errorCode = null,
    )
}

/**
 * Strictly decodes versioned canonical text; corrupt or hand-tampered input never
 * becomes an empty or partially-trusted aggregate. Every decoded aggregate re-encodes
 * to byte-identical text, so a snapshot that parses but disagrees with its own
 * canonical form (reordered rows, out-of-range sub-counts, a forged total) is rejected
 * the same way malformed bytes are.
 */
public fun decodeSessionAggregateSnapshot(
    encoded: String,
): SessionAggregateSnapshotLoadResult {
    if (encoded.encodeToByteArray().size > MAX_SESSION_AGGREGATE_SNAPSHOT_BYTES) {
        return invalidSnapshot("snapshot_too_large")
    }

    return try {
        val aggregate = parseSessionAggregateSnapshot(encoded)
        val reencoded = encodeSessionAggregateSnapshot(aggregate)
        if (!reencoded.isSuccess || reencoded.snapshotText != encoded) {
            invalidSnapshot("noncanonical_snapshot")
        } else {
            SessionAggregateSnapshotLoadResult(
                aggregate = aggregate,
                isSuccess = true,
                errorCode = null,
            )
        }
    } catch (_: Exception) {
        invalidSnapshot("invalid_snapshot")
    }
}

private fun parseSessionAggregateSnapshot(encoded: String): SessionAggregate {
    require('\r' !in encoded)
    require(encoded.endsWith('\n'))
    val lines = encoded.dropLast(1).split('\n')
    val reader = SnapshotReader(lines)

    require(reader.nextLine() == SNAPSHOT_HEADER)
    val deviceCount = reader.readIntField("device-count", minimum = 0)
    val observationCount = reader.readIntField("observation-count", minimum = 0)
    val observationsWithoutDisplayIdCount =
        reader.readIntField("observations-without-display-id-count", minimum = 0)
    val mutualDeviceCount = reader.readIntField("mutual-device-count", minimum = 0)
    val mutualObservationCount = reader.readIntField("mutual-observation-count", minimum = 0)
    val mutualObservationsWithoutDisplayIdCount =
        reader.readIntField("mutual-observations-without-display-id-count", minimum = 0)

    require(observationsWithoutDisplayIdCount <= observationCount)
    require(deviceCount <= observationCount - observationsWithoutDisplayIdCount)
    require(mutualObservationCount <= observationCount)
    require(mutualObservationsWithoutDisplayIdCount <= observationsWithoutDisplayIdCount)
    require(mutualObservationsWithoutDisplayIdCount <= mutualObservationCount)
    require(mutualDeviceCount <= deviceCount)
    require(mutualDeviceCount <= mutualObservationCount - mutualObservationsWithoutDisplayIdCount)

    val windowCount = reader.readCountField("windows")
    val windows = buildList(windowCount) {
        repeat(windowCount) {
            val fields = reader.nextFields(expectedCount = 6)
            require(fields[0] == "window")
            val windowIndex = fields[1].parseCanonicalLong(minimum = 0L)
            val peerCount = fields[2].parseCanonicalInt(minimum = 0)
            val windowObservationCount = fields[3].parseCanonicalInt(minimum = 0)
            val mutualPeerCount = fields[4].parseCanonicalInt(minimum = 0)
            val windowMutualObservationCount = fields[5].parseCanonicalInt(minimum = 0)
            require(peerCount <= windowObservationCount)
            require(mutualPeerCount <= peerCount)
            require(windowMutualObservationCount <= windowObservationCount)
            require(mutualPeerCount <= windowMutualObservationCount)
            add(
                WindowAggregate(
                    windowIndex = windowIndex,
                    peerCount = peerCount,
                    observationCount = windowObservationCount,
                    mutualPeerCount = mutualPeerCount,
                    mutualObservationCount = windowMutualObservationCount,
                ),
            )
        }
    }
    require(windows.map { it.windowIndex }.toSet().size == windows.size)
    require(windows == windows.sortedBy { it.windowIndex })

    val bandCount = reader.readCountField("bands")
    val bands = buildList(bandCount) {
        repeat(bandCount) {
            val fields = reader.nextFields(expectedCount = 9)
            require(fields[0] == "band")
            val bandIndex = fields[1].parseCanonicalLong(minimum = 0L)
            val windowsPerBand = fields[2].parseCanonicalInt(minimum = 1)
            val bandDeviceCount = fields[3].parseCanonicalInt(minimum = 0)
            val bandObservationCount = fields[4].parseCanonicalInt(minimum = 0)
            val bandObservationsWithoutDisplayIdCount = fields[5].parseCanonicalInt(minimum = 0)
            val bandMutualDeviceCount = fields[6].parseCanonicalInt(minimum = 0)
            val bandMutualObservationCount = fields[7].parseCanonicalInt(minimum = 0)
            val bandMutualObservationsWithoutDisplayIdCount = fields[8].parseCanonicalInt(minimum = 0)
            require(bandObservationsWithoutDisplayIdCount <= bandObservationCount)
            require(bandDeviceCount <= bandObservationCount - bandObservationsWithoutDisplayIdCount)
            require(bandMutualObservationCount <= bandObservationCount)
            require(bandMutualObservationsWithoutDisplayIdCount <= bandObservationsWithoutDisplayIdCount)
            require(bandMutualObservationsWithoutDisplayIdCount <= bandMutualObservationCount)
            require(bandMutualDeviceCount <= bandDeviceCount)
            require(
                bandMutualDeviceCount <=
                    bandMutualObservationCount - bandMutualObservationsWithoutDisplayIdCount,
            )
            add(
                BandAggregate(
                    bandIndex = bandIndex,
                    windowsPerBand = windowsPerBand,
                    deviceCount = bandDeviceCount,
                    observationCount = bandObservationCount,
                    observationsWithoutDisplayIdCount = bandObservationsWithoutDisplayIdCount,
                    mutualDeviceCount = bandMutualDeviceCount,
                    mutualObservationCount = bandMutualObservationCount,
                    mutualObservationsWithoutDisplayIdCount = bandMutualObservationsWithoutDisplayIdCount,
                ),
            )
        }
    }
    require(bands.map { it.bandIndex }.toSet().size == bands.size)
    require(bands == bands.sortedBy { it.bandIndex })
    require(bands.map { it.windowsPerBand }.toSet().size <= 1)

    require(reader.nextLine() == "end")
    require(reader.isExhausted())

    return SessionAggregate(
        windows = windows,
        bands = bands,
        isSuccess = true,
        errorCode = null,
        deviceCount = deviceCount,
        observationCount = observationCount,
        observationsWithoutDisplayIdCount = observationsWithoutDisplayIdCount,
        mutualDeviceCount = mutualDeviceCount,
        mutualObservationCount = mutualObservationCount,
        mutualObservationsWithoutDisplayIdCount = mutualObservationsWithoutDisplayIdCount,
    )
}

private class SnapshotReader(
    private val lines: List<String>,
) {
    private var index: Int = 0

    fun nextLine(): String {
        require(index < lines.size)
        return lines[index++]
    }

    fun nextFields(expectedCount: Int): List<String> =
        nextLine().split('\t').also { require(it.size == expectedCount) }

    fun readTextField(name: String): String {
        val fields = nextFields(expectedCount = 2)
        require(fields[0] == name)
        return fields[1]
    }

    fun readIntField(name: String, minimum: Int): Int =
        readTextField(name).parseCanonicalInt(minimum)

    fun readCountField(name: String): Int {
        val count = readIntField(name, minimum = 0)
        require(count <= MAX_AGGREGATION_OBSERVATION_COUNT)
        return count
    }

    fun isExhausted(): Boolean = index == lines.size
}

private fun String.parseCanonicalLong(minimum: Long): Long {
    require(isNotEmpty())
    require(this == "0" || (first() in '1'..'9' && all { it in '0'..'9' }))
    val parsed = toLongOrNull()
    require(parsed != null && parsed >= minimum)
    return parsed
}

private fun String.parseCanonicalInt(minimum: Int): Int {
    val parsed = parseCanonicalLong(minimum.toLong())
    require(parsed <= Int.MAX_VALUE.toLong())
    return parsed.toInt()
}

private fun invalidSnapshot(errorCode: String): SessionAggregateSnapshotLoadResult =
    SessionAggregateSnapshotLoadResult(
        aggregate = null,
        isSuccess = false,
        errorCode = errorCode,
    )

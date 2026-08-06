package org.levarac.beid.shared.report

private const val SNAPSHOT_HEADER = "beid-ledger-snapshot\t1"
internal const val MAX_LEDGER_SNAPSHOT_BYTES = 8 * 1024 * 1024
internal const val MAX_LEDGER_RECORD_COUNT = 100_000
internal const val MAX_LEDGER_TEXT_FIELD_BYTES = 4 * 1024
private val SUBMISSION_KEY = Regex("[0-9a-f]{48}")

/** Returns the canonical UTF-8 snapshot text that native storage must persist atomically. */
public fun encodeUnsentWindowLedgerSnapshot(
    ledger: UnsentWindowLedger,
): String = buildString {
    val state = ledger.state
    val windows = state.windows.sortedWith(
        compareBy<LedgerWindow> { it.openedSequence }.thenBy { it.windowId },
    )
    val windowsById = windows.associateBy { it.windowId }
    val reports = state.reports.sortedBy { it.submissionKey }

    append(SNAPSHOT_HEADER).append('\n')
    append("revision\t").append(state.revision).append('\n')
    append("ledger-id\t").append(state.ledgerInstanceIdHex).append('\n')
    append("next-window-sequence\t").append(state.nextWindowSequence).append('\n')
    append("next-report-sequence\t").append(state.nextReportSequence).append('\n')
    append("windows\t").append(windows.size).append('\n')
    windows.forEach { window ->
        append("window\t")
            .append(window.windowId.encodeUtf8Hex())
            .append('\t')
            .append(window.openedSequence)
            .append('\t')
            .append(window.closedRevision ?: "-")
            .append('\t')
            .append(window.observationReference?.encodeUtf8Hex() ?: "-")
            .append('\n')
    }
    append("reports\t").append(reports.size).append('\n')
    reports.forEach { report ->
        val statusToken: String
        val statusDetail: String
        val inclusionDetail: String
        when (report.status) {
            LedgerReportStatus.IN_FLIGHT -> {
                statusToken = "in_flight"
                statusDetail = "-"
                inclusionDetail = "-"
            }

            LedgerReportStatus.RETRYABLE_FAILED -> {
                statusToken = "retryable_failed"
                statusDetail = checkNotNull(report.retryNotBeforeEpochMilliseconds).toString()
                inclusionDetail = "-"
            }

            LedgerReportStatus.ACKNOWLEDGED -> {
                statusToken = "acknowledged"
                statusDetail = checkNotNull(report.acceptanceReceiptReference).encodeUtf8Hex()
                inclusionDetail = report.inclusionReceiptReference?.encodeUtf8Hex() ?: "-"
            }
        }

        append("report\t")
            .append(report.submissionKey)
            .append('\t')
            .append(report.updatedRevision)
            .append('\t')
            .append(report.attempt)
            .append('\t')
            .append(statusToken)
            .append('\t')
            .append(statusDetail)
            .append('\t')
            .append(inclusionDetail)
            .append('\t')
            .append(
                report.windowIds
                    .canonicalMembershipOrder(windowsById)
                    .joinToString(",") { it.encodeUtf8Hex() },
            )
            .append('\n')
    }
    append("end\n")
}

/** Strictly decodes versioned canonical text; corrupt input never becomes an empty ledger. */
public fun decodeUnsentWindowLedgerSnapshot(
    encoded: String,
): UnsentWindowLedgerLoadResult {
    if (encoded.encodeToByteArray().size > MAX_LEDGER_SNAPSHOT_BYTES) {
        return invalidSnapshot("snapshot_too_large")
    }

    return try {
        val state = parseSnapshot(encoded)
        val ledger = UnsentWindowLedger(state)
        if (encodeUnsentWindowLedgerSnapshot(ledger) != encoded) {
            invalidSnapshot("noncanonical_snapshot")
        } else {
            UnsentWindowLedgerLoadResult(
                ledger = ledger,
                isSuccess = true,
                persistenceRevision = state.revision,
                errorCode = null,
            )
        }
    } catch (_: Exception) {
        invalidSnapshot("invalid_snapshot")
    }
}

private fun parseSnapshot(encoded: String): LedgerState {
    require('\r' !in encoded)
    require(encoded.endsWith('\n'))
    val lines = encoded.dropLast(1).split('\n')
    val reader = SnapshotReader(lines)

    require(reader.nextLine() == SNAPSHOT_HEADER)
    val revision = reader.readLongField("revision", minimum = 0L)
    val ledgerInstanceIdHex = reader.readTextField("ledger-id")
    require(Regex("[0-9a-f]{32}").matches(ledgerInstanceIdHex))
    val nextWindowSequence = reader.readLongField(
        name = "next-window-sequence",
        minimum = 1L,
    )
    val nextReportSequence = reader.readLongField(
        name = "next-report-sequence",
        minimum = 1L,
    )

    val windowCount = reader.readCountField("windows")
    val windows = buildList(windowCount) {
        repeat(windowCount) {
            val fields = reader.nextFields(expectedCount = 5)
            require(fields[0] == "window")
            val windowId = fields[1].decodeUtf8Hex()
            require(windowId.isNotEmpty())
            require(windowId.encodeToByteArray().size <= MAX_LEDGER_TEXT_FIELD_BYTES)
            val openedSequence = fields[2].parseCanonicalLong(minimum = 1L)
            val closedRevision: Long?
            val observationReference: String?
            if (fields[3] == "-") {
                require(fields[4] == "-")
                closedRevision = null
                observationReference = null
            } else {
                closedRevision = fields[3].parseCanonicalLong(minimum = 1L).also {
                    require(it <= revision)
                }
                observationReference = fields[4].decodeUtf8Hex().also {
                    require(it.isNotEmpty())
                    require(it.encodeToByteArray().size <= MAX_LEDGER_TEXT_FIELD_BYTES)
                }
            }
            add(
                LedgerWindow(
                    windowId = windowId,
                    openedSequence = openedSequence,
                    closedRevision = closedRevision,
                    observationReference = observationReference,
                ),
            )
        }
    }
    require(windows.map { it.windowId }.toSet().size == windows.size)
    require(windows.map { it.openedSequence }.toSet().size == windows.size)
    require(windows.all { it.openedSequence < nextWindowSequence })
    require(
        windows == windows.sortedWith(
            compareBy<LedgerWindow> { it.openedSequence }.thenBy { it.windowId },
        ),
    )

    val reportCount = reader.readCountField("reports")
    val reports = buildList(reportCount) {
        repeat(reportCount) {
            val fields = reader.nextFields(expectedCount = 8)
            require(fields[0] == "report")
            val submissionKey = fields[1]
            require(SUBMISSION_KEY.matches(submissionKey))
            require(submissionKey.startsWith(ledgerInstanceIdHex))
            val sequenceText = submissionKey.takeLast(16)
            val sequence = sequenceText.toLongOrNull(radix = 16)
            require(sequence != null && sequence > 0L)
            require(sequenceText == sequence.toString(16).padStart(16, '0'))
            require(sequence < nextReportSequence)

            val updatedRevision = fields[2].parseCanonicalLong(minimum = 1L)
            require(updatedRevision <= revision)
            val attemptLong = fields[3].parseCanonicalLong(minimum = 1L)
            require(attemptLong <= Int.MAX_VALUE.toLong())
            val attempt = attemptLong.toInt()

            val status: LedgerReportStatus
            val retryNotBefore: Long?
            val acceptanceReceiptReference: String?
            val inclusionReceiptReference: String?
            when (fields[4]) {
                "in_flight" -> {
                    require(fields[5] == "-")
                    require(fields[6] == "-")
                    status = LedgerReportStatus.IN_FLIGHT
                    retryNotBefore = null
                    acceptanceReceiptReference = null
                    inclusionReceiptReference = null
                }

                "retryable_failed" -> {
                    require(fields[6] == "-")
                    status = LedgerReportStatus.RETRYABLE_FAILED
                    retryNotBefore = fields[5].parseCanonicalLong(minimum = 0L)
                    acceptanceReceiptReference = null
                    inclusionReceiptReference = null
                }

                "acknowledged" -> {
                    status = LedgerReportStatus.ACKNOWLEDGED
                    retryNotBefore = null
                    acceptanceReceiptReference = fields[5].decodeUtf8Hex().also {
                        require(it.isNotEmpty())
                        require(it.encodeToByteArray().size <= MAX_LEDGER_TEXT_FIELD_BYTES)
                    }
                    inclusionReceiptReference = if (fields[6] == "-") {
                        null
                    } else {
                        fields[6].decodeUtf8Hex().also {
                            require(it.isNotEmpty())
                            require(it.encodeToByteArray().size <= MAX_LEDGER_TEXT_FIELD_BYTES)
                        }
                    }
                }

                else -> error("Unknown report status")
            }

            require(fields[7].isNotEmpty())
            val windowIds = fields[7].split(',').map { it.decodeUtf8Hex() }
            require(windowIds.all { it.isNotEmpty() })
            require(windowIds.toSet().size == windowIds.size)
            add(
                LedgerReport(
                    submissionKey = submissionKey,
                    updatedRevision = updatedRevision,
                    attempt = attempt,
                    windowIds = windowIds,
                    status = status,
                    retryNotBeforeEpochMilliseconds = retryNotBefore,
                    acceptanceReceiptReference = acceptanceReceiptReference,
                    inclusionReceiptReference = inclusionReceiptReference,
                ),
            )
        }
    }
    require(reader.nextLine() == "end")
    require(reader.isExhausted())

    require(reports.map { it.submissionKey }.toSet().size == reports.size)
    require(reports == reports.sortedBy { it.submissionKey })
    require(reports.count { it.status != LedgerReportStatus.ACKNOWLEDGED } <= 1)

    val windowsById = windows.associateBy { it.windowId }
    val membership = mutableMapOf<String, String>()
    reports.forEach { report ->
        require(report.windowIds == report.windowIds.canonicalMembershipOrder(windowsById))
        report.windowIds.forEach { windowId ->
            val window = requireNotNull(windowsById[windowId])
            val closedRevision = requireNotNull(window.closedRevision)
            require(closedRevision <= report.updatedRevision)
            require(membership.put(windowId, report.submissionKey) == null)
        }
    }

    return LedgerState(
        ledgerInstanceIdHex = ledgerInstanceIdHex,
        revision = revision,
        durableRevision = revision,
        nextWindowSequence = nextWindowSequence,
        nextReportSequence = nextReportSequence,
        windows = windows.map { window ->
            window.copy(reportKey = membership[window.windowId])
        },
        reports = reports,
        lastEmittedReportRevision = null,
    )
}

private fun List<String>.canonicalMembershipOrder(
    windowsById: Map<String, LedgerWindow>,
): List<String> = sortedWith(
    compareBy<String> { windowId ->
        windowsById[windowId]?.closedRevision ?: Long.MAX_VALUE
    }.thenBy { it },
)

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

    fun readLongField(name: String, minimum: Long): Long =
        readTextField(name).parseCanonicalLong(minimum)

    fun readCountField(name: String): Int {
        val count = readLongField(name, minimum = 0L)
        require(count <= MAX_LEDGER_RECORD_COUNT.toLong())
        return count.toInt()
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

private fun String.encodeUtf8Hex(): String =
    encodeToByteArray(throwOnInvalidSequence = true).joinToString(separator = "") { byte ->
        (byte.toInt() and 0xff).toString(16).padStart(2, '0')
    }

private fun String.decodeUtf8Hex(): String {
    require(length % 2 == 0)
    require(all { it in '0'..'9' || it in 'a'..'f' })
    val bytes = ByteArray(length / 2) { index ->
        val offset = index * 2
        substring(offset, offset + 2).toInt(radix = 16).toByte()
    }
    val decoded = bytes.decodeToString(throwOnInvalidSequence = true)
    require(decoded.encodeUtf8Hex() == this)
    return decoded
}

private fun invalidSnapshot(errorCode: String): UnsentWindowLedgerLoadResult =
    UnsentWindowLedgerLoadResult(
        ledger = null,
        isSuccess = false,
        persistenceRevision = 0L,
        errorCode = errorCode,
    )

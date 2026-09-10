package org.levarac.beid.shared.report

private const val DRAFT_SNAPSHOT_HEADER = "beid-window-observation-draft\t1"

/**
 * Returns the canonical UTF-8 snapshot text that native storage must persist
 * atomically for the window that is open right now.
 *
 * Observed RPIDs are written in the order the device saw them. That order is
 * not what the signed observation is built from — preparation sorts and
 * de-duplicates the set itself — but a canonical text needs exactly one
 * spelling per value, and preserving arrival order is the spelling that a
 * decode can hand straight back to an accumulator without inventing an order
 * of its own.
 */
public fun encodeWindowObservationDraftSnapshot(
    draft: WindowObservationDraft,
): String = buildString {
    val state = draft.state
    append(DRAFT_SNAPSHOT_HEADER).append('\n')
    append("window\t").append(state.windowId.encodeDraftUtf8Hex()).append('\n')
    append("enin\t").append(state.enin).append('\n')
    append("event-code\t").append(state.eventCode.encodeDraftUtf8Hex()).append('\n')
    append("event-id\t").append(state.eventIdHex).append('\n')
    append("event-definition-digest\t").append(state.eventDefinitionDigestHex).append('\n')
    append("participant-commitment\t").append(state.participantCommitmentHex ?: "-").append('\n')
    append("reporter-rpid\t").append(state.reporterRpidHex).append('\n')
    append("observed-rpids\t").append(state.observedRpidHexes.size).append('\n')
    state.observedRpidHexes.forEach { rpid ->
        append("rpid\t").append(rpid).append('\n')
    }
    append("end\n")
}

/**
 * Strictly decodes versioned canonical text. Corrupt input never becomes an
 * empty draft: a draft that cannot be read is *absent* evidence, and absent
 * evidence must not be mistaken for a window in which nothing was observed.
 */
public fun decodeWindowObservationDraftSnapshot(
    encoded: String,
): WindowObservationDraftResult {
    if (encoded.encodeToByteArray().size > MAX_DRAFT_SNAPSHOT_BYTES) {
        return draftFailure("snapshot_too_large")
    }

    return try {
        val draft = parseDraftSnapshot(encoded)
        if (encodeWindowObservationDraftSnapshot(draft) != encoded) {
            draftFailure("noncanonical_snapshot")
        } else {
            WindowObservationDraftResult(draft = draft, isSuccess = true, errorCode = null)
        }
    } catch (_: Exception) {
        draftFailure("invalid_snapshot")
    }
}

private fun parseDraftSnapshot(encoded: String): WindowObservationDraft {
    require('\r' !in encoded)
    require(encoded.endsWith('\n'))
    val lines = encoded.substring(0, encoded.length - 1).split('\n')
    val reader = DraftLineReader(lines)

    require(reader.next() == DRAFT_SNAPSHOT_HEADER)
    val windowId = reader.field("window").decodeDraftUtf8Hex()
    val enin = reader.field("enin").parseDraftCanonicalLong()
    val eventCode = reader.field("event-code").decodeDraftUtf8Hex()
    val eventIdHex = reader.field("event-id")
    val eventDefinitionDigestHex = reader.field("event-definition-digest")
    val participantCommitment = reader.field("participant-commitment").let {
        if (it == "-") null else it
    }
    val reporterRpidHex = reader.field("reporter-rpid")
    val rpidCount = reader.field("observed-rpids").parseDraftCanonicalLong()
    require(rpidCount <= MAX_DRAFT_OBSERVED_RPID_COUNT.toLong())

    val created = createWindowObservationDraft(
        windowId = windowId,
        enin = enin,
        eventCode = eventCode,
        eventIdHex = eventIdHex,
        eventDefinitionDigestHex = eventDefinitionDigestHex,
        participantCommitmentHex = participantCommitment,
        reporterRpidHex = reporterRpidHex,
    )
    var draft = requireNotNull(created.draft)

    repeat(rpidCount.toInt()) {
        val rpid = reader.field("rpid")
        val appended = addWindowObservationDraftRpid(draft, rpid)
        val next = requireNotNull(appended.draft)
        // A repeat inside one canonical snapshot is a duplicate row, not a
        // repeated detection: the count line promised that many distinct
        // values, so a no-op append means the text was malformed.
        require(next.observedRpidCount == draft.observedRpidCount + 1)
        draft = next
    }

    require(reader.next() == "end")
    require(reader.isExhausted())
    return draft
}

private class DraftLineReader(private val lines: List<String>) {
    private var index = 0

    fun next(): String {
        require(index < lines.size)
        return lines[index++]
    }

    fun field(name: String): String {
        val line = next()
        val prefix = "$name\t"
        require(line.startsWith(prefix))
        val value = line.substring(prefix.length)
        require('\t' !in value)
        return value
    }

    fun isExhausted(): Boolean = index == lines.size
}

private fun String.parseDraftCanonicalLong(): Long {
    require(isNotEmpty())
    require(this == "0" || (first() in '1'..'9' && all { it in '0'..'9' }))
    val parsed = toLongOrNull()
    require(parsed != null && parsed >= 0L)
    return parsed
}

private fun String.encodeDraftUtf8Hex(): String =
    encodeToByteArray(throwOnInvalidSequence = true).joinToString(separator = "") { byte ->
        (byte.toInt() and 0xff).toString(16).padStart(2, '0')
    }

private fun String.decodeDraftUtf8Hex(): String {
    require(length % 2 == 0)
    require(all { it in '0'..'9' || it in 'a'..'f' })
    val bytes = ByteArray(length / 2) { index ->
        val offset = index * 2
        substring(offset, offset + 2).toInt(radix = 16).toByte()
    }
    val decoded = bytes.decodeToString(throwOnInvalidSequence = true)
    require(decoded.encodeDraftUtf8Hex() == this)
    return decoded
}

package org.levarac.beid.shared.sigil

import org.levarac.beid.shared.aggregation.AggregationObservationInput

/*
 * Sigil presence (beid#653, docs/decisions/issue-653-design.md).
 *
 * KMP ledger row (docs/kmp-shared-foundation.md section 1):
 *
 *   family: sigil presence | class: C / INVENT
 *   current_ios: none | current_android: none (no Android Sigil surface;
 *     an Android caller must call this module rather than port it)
 *   ruling_or_invariant: invariants 1-8 below; DECISIONS 2026-09-27 lines (a)-(d)
 *   owner: beid#653 | shared_symbol: org.levarac.beid.shared.sigil.*SigilPresence*
 *   licensing_test: SigilPresenceTest | platform_callers: iOS SensingCoordinator
 *
 * What this is. The per-record input a real Sigil needs: which peer was
 * present in which window. It is derived from the SAME observations the
 * session aggregate counts, so the drawn peers are exactly the ones behind
 * `deviceCount` and the rings are exactly `windowCount`.
 *
 * The owner authorized keeping this ON THE DEVICE ONLY. Nothing here is part
 * of a submission, a signature or a public artifact, and nothing may make it
 * one (#145; treated like DESIGN.md rule 13).
 *
 * Invariants (each pinned by SigilPresenceTest):
 *
 *  1. Tokens are supplied by the caller from a CSPRNG (randomness is a port,
 *     docs/kmp-shared-foundation.md step 3) and stored verbatim. A token is
 *     never derived from a display id, so the stored text says nothing about
 *     one, and the same peer gets unrelated tokens in two records. The
 *     display id -> token map lives only in [SigilPresenceSession] (memory).
 *  2. A token is exactly [SIGIL_PRESENCE_TOKEN_LENGTH] lowercase hex
 *     characters. A duplicate token fails the whole session permanently (a
 *     repeating source, e.g. an all-zero failed CSPRNG, must never merge two
 *     peers into one); a malformed token is refused and assigns nothing.
 *  3. Tokens are assigned to display ids in first-seen order. Observations
 *     without a display id are never peers (their only identifier rotates
 *     every window), but their windows still count.
 *  4. Windows are ranks over the distinct observed ENINs, ascending: W equals
 *     the session aggregate's `windowCount`. No ENIN is stored.
 *  5. Presence is 1. This family has no mutual input and v1 text has no
 *     presence column, so presence 2 cannot be produced (DECISIONS
 *     2026-08-09; #144 Stage 4 is the only possible source).
 *  6. More than [MAX_SIGIL_PEER_COUNT] distinct display ids fails the record
 *     (`too_many_peers`): nothing is written and the record keeps its neutral
 *     ring. There is no partial Sigil.
 *  7. The text is strict and canonical: a decoded text re-encodes to
 *     identical bytes, and anything else is rejected, never partially trusted.
 *  8. A session is bound to the first observation input it sees; any other
 *     input is refused (`input_mismatch`) and changes nothing.
 */

/** Hex characters in one token: 16 CSPRNG bytes. */
internal const val SIGIL_PRESENCE_TOKEN_LENGTH = 32

/** Largest text encoded or decoded. The worst real record is about 0.64 MB. */
internal const val MAX_SIGIL_PRESENCE_SNAPSHOT_BYTES = 8 * 1024 * 1024

private const val SIGIL_PRESENCE_HEADER = "beid-sigil-presence\t1"

/**
 * In-memory state for one recording session: the display id -> token map.
 * Never persisted; the native owner drops it when the session ends.
 */
public class SigilPresenceSession internal constructor() {
    internal var boundInput: AggregationObservationInput? = null
    internal var scannedObservationCount: Int = 0
    internal val tokenByDisplayId: HashMap<String, String> = HashMap()
    internal val awaitingToken: ArrayDeque<String> = ArrayDeque()
    internal val seenDisplayIds: HashSet<String> = HashSet()
    internal val assignedTokens: HashSet<String> = HashSet()
    internal var overflowed: Boolean = false
    internal var duplicateToken: Boolean = false
}

/** A Sigil input built from a live session. `input` is null unless `isSuccess`. */
public class SigilPresenceInputResult internal constructor(
    public val isSuccess: Boolean,
    public val errorCode: String?,
    public val input: SigilInput?,
)

/** The canonical text to persist for one record. `snapshotText` is null unless `isSuccess`. */
public class SigilPresenceSnapshotEncodeResult internal constructor(
    public val isSuccess: Boolean,
    public val snapshotText: String?,
    public val errorCode: String?,
)

/** A stored text turned back into a Sigil input. `input` is null unless `isSuccess`. */
public class SigilPresenceSnapshotLoadResult internal constructor(
    public val isSuccess: Boolean,
    public val errorCode: String?,
    public val input: SigilInput?,
)

internal class SigilPresenceTable(
    val windowCount: Int,
    /** Sorted by token; each rank list strictly ascending and non-empty. */
    val peers: List<Pair<String, IntArray>>,
)

private sealed class SigilPresenceOutcome {
    class Built(val table: SigilPresenceTable) : SigilPresenceOutcome()
    class Failed(val errorCode: String) : SigilPresenceOutcome()
}

public fun createSigilPresenceSession(): SigilPresenceSession = SigilPresenceSession()

/**
 * How many display ids seen so far still need a token. The caller supplies
 * that many CSPRNG tokens through [addSigilPresenceToken]. Returns 0 once the
 * session can no longer produce a record (overflow, duplicate token) or for
 * an input other than the bound one.
 */
public fun sigilPresenceTokensNeeded(session: SigilPresenceSession, observations: AggregationObservationInput): Int {
    if (!session.sync(observations)) {
        return 0
    }
    if (session.overflowed || session.duplicateToken) {
        return 0
    }
    return session.awaitingToken.size
}

/**
 * Assigns [token] to the earliest-seen display id that has none. Returns false,
 * assigning nothing, for a malformed token, when no display id is waiting, for
 * a failed session or a foreign input. A token already assigned in this
 * session returns false and fails the session for good (invariant 2).
 */
public fun addSigilPresenceToken(
    session: SigilPresenceSession,
    observations: AggregationObservationInput,
    token: String,
): Boolean {
    if (!session.sync(observations)) {
        return false
    }
    if (session.overflowed || session.duplicateToken) {
        return false
    }
    if (!token.isValidSigilPresenceToken()) {
        return false
    }
    if (session.awaitingToken.isEmpty()) {
        return false
    }
    if (token in session.assignedTokens) {
        session.duplicateToken = true
        return false
    }
    val displayId = session.awaitingToken.removeFirst()
    session.tokenByDisplayId[displayId] = token
    session.assignedTokens += token
    return true
}

/** The live Sigil input for the session so far (frame 04's in-progress card). */
public fun buildSigilPresenceInput(
    session: SigilPresenceSession,
    observations: AggregationObservationInput,
): SigilPresenceInputResult =
    when (val outcome = session.table(observations)) {
        is SigilPresenceOutcome.Failed -> SigilPresenceInputResult(false, outcome.errorCode, null)
        is SigilPresenceOutcome.Built -> {
            val input = outcome.table.toSigilInput()
            if (input == null) {
                SigilPresenceInputResult(false, "invalid_presence", null)
            } else {
                SigilPresenceInputResult(true, null, input)
            }
        }
    }

/** The canonical text to persist for the finished session's record. */
public fun encodeSigilPresenceSnapshot(
    session: SigilPresenceSession,
    observations: AggregationObservationInput,
): SigilPresenceSnapshotEncodeResult {
    val text = when (val outcome = session.table(observations)) {
        is SigilPresenceOutcome.Failed -> return SigilPresenceSnapshotEncodeResult(false, null, outcome.errorCode)
        is SigilPresenceOutcome.Built -> outcome.table.encode()
    }
    if (!text.fitsSigilPresenceCap()) {
        return SigilPresenceSnapshotEncodeResult(false, null, "snapshot_too_large")
    }
    return SigilPresenceSnapshotEncodeResult(true, text, null)
}

/** Strictly decodes stored text (invariant 7) into a Sigil input. */
public fun decodeSigilPresenceSnapshot(encoded: String): SigilPresenceSnapshotLoadResult {
    if (!encoded.fitsSigilPresenceCap()) {
        return SigilPresenceSnapshotLoadResult(false, "snapshot_too_large", null)
    }
    val table = try {
        parseSigilPresenceSnapshot(encoded)
    } catch (_: Exception) {
        return SigilPresenceSnapshotLoadResult(false, "invalid_snapshot", null)
    }
    if (table.encode() != encoded) {
        return SigilPresenceSnapshotLoadResult(false, "noncanonical_snapshot", null)
    }
    val input = table.toSigilInput()
        ?: return SigilPresenceSnapshotLoadResult(false, "invalid_snapshot", null)
    return SigilPresenceSnapshotLoadResult(true, null, input)
}

/** Binds on first use and scans observations added since the last call. */
private fun SigilPresenceSession.sync(observations: AggregationObservationInput): Boolean {
    val bound = boundInput
    if (bound == null) {
        boundInput = observations
    } else if (bound !== observations) {
        return false
    }
    val rows = observations.observations
    if (rows.size < scannedObservationCount) {
        return false
    }
    for (index in scannedObservationCount until rows.size) {
        val displayId = rows[index].displayId ?: continue
        if (displayId in seenDisplayIds) continue
        if (seenDisplayIds.size >= MAX_SIGIL_PEER_COUNT) {
            overflowed = true
            continue
        }
        seenDisplayIds += displayId
        awaitingToken.addLast(displayId)
    }
    scannedObservationCount = rows.size
    return true
}

private fun SigilPresenceSession.table(observations: AggregationObservationInput): SigilPresenceOutcome {
    if (!sync(observations)) {
        return SigilPresenceOutcome.Failed("input_mismatch")
    }
    if (duplicateToken) {
        return SigilPresenceOutcome.Failed("duplicate_token")
    }
    if (overflowed) {
        return SigilPresenceOutcome.Failed("too_many_peers")
    }
    if (awaitingToken.isNotEmpty()) {
        return SigilPresenceOutcome.Failed("missing_token")
    }
    val rows = observations.observations
    if (rows.isEmpty()) {
        return SigilPresenceOutcome.Failed("no_windows")
    }
    val windows = rows.map { it.windowIndex }.distinct().sorted()
    if (windows.size > MAX_SIGIL_WINDOW_COUNT) {
        return SigilPresenceOutcome.Failed("too_many_windows")
    }
    val rankByWindow = HashMap<Long, Int>()
    windows.forEachIndexed { rank, window -> rankByWindow[window] = rank }
    val ranksByToken = HashMap<String, HashSet<Int>>()
    rows.forEach { row ->
        val displayId = row.displayId ?: return@forEach
        val token = tokenByDisplayId.getValue(displayId)
        ranksByToken.getOrPut(token) { HashSet() } += rankByWindow.getValue(row.windowIndex)
    }
    return SigilPresenceOutcome.Built(
        SigilPresenceTable(
            windowCount = windows.size,
            peers = ranksByToken.keys.sorted().map { token ->
                token to ranksByToken.getValue(token).sorted().toIntArray()
            },
        ),
    )
}

/** Presence is the literal 1 (invariant 5). Null if the layout input refuses an entry. */
private fun SigilPresenceTable.toSigilInput(): SigilInput? {
    val input = createSigilInput(windowCount)
    peers.forEach { (token, ranks) ->
        ranks.forEach { rank ->
            if (!addSigilPresence(input, token, rank, 1)) {
                return null
            }
        }
    }
    return input
}

private fun SigilPresenceTable.encode(): String = buildString {
    append(SIGIL_PRESENCE_HEADER).append('\n')
    append("windows\t").append(windowCount).append('\n')
    append("peers\t").append(peers.size).append('\n')
    peers.forEach { (token, ranks) ->
        append("peer\t").append(token).append('\t')
        ranks.forEachIndexed { index, rank ->
            if (index > 0) append(',')
            append(rank)
        }
        append('\n')
    }
    append("end\n")
}

private fun parseSigilPresenceSnapshot(encoded: String): SigilPresenceTable {
    require('\r' !in encoded)
    require(encoded.endsWith('\n'))
    val lines = encoded.dropLast(1).split('\n')
    var cursor = 0
    fun next(): String {
        require(cursor < lines.size)
        return lines[cursor++]
    }

    require(next() == SIGIL_PRESENCE_HEADER)
    val windowCount = parseField(next(), "windows")
    require(windowCount >= 1 && windowCount <= MAX_SIGIL_WINDOW_COUNT)
    val peerCount = parseField(next(), "peers")
    require(peerCount <= MAX_SIGIL_PEER_COUNT)

    val peers = ArrayList<Pair<String, IntArray>>(peerCount)
    var entryCount = 0
    var previousToken: String? = null
    repeat(peerCount) {
        val parts = next().split('\t')
        require(parts.size == 3 && parts[0] == "peer")
        val token = parts[1]
        require(token.isValidSigilPresenceToken())
        require(previousToken == null || previousToken!! < token)
        previousToken = token
        val ranks = parts[2].split(',').map { parseDigits(it) }.toIntArray()
        for (index in ranks.indices) {
            require(ranks[index] < windowCount)
            require(index == 0 || ranks[index - 1] < ranks[index])
        }
        entryCount += ranks.size
        require(entryCount <= MAX_SIGIL_ENTRY_COUNT)
        peers += token to ranks
    }
    require(next() == "end")
    require(cursor == lines.size)
    return SigilPresenceTable(windowCount, peers)
}

private fun parseField(line: String, name: String): Int {
    val parts = line.split('\t')
    require(parts.size == 2 && parts[0] == name)
    return parseDigits(parts[1])
}

/** Digits only: no sign, no space. Leading zeros parse and then fail the canonical re-encode. */
private fun parseDigits(text: String): Int {
    require(text.isNotEmpty() && text.all { it in '0'..'9' })
    return text.toInt()
}

private fun String.isValidSigilPresenceToken(): Boolean =
    length == SIGIL_PRESENCE_TOKEN_LENGTH && all { it in '0'..'9' || it in 'a'..'f' }

private fun String.fitsSigilPresenceCap(): Boolean =
    encodeToByteArray().size <= MAX_SIGIL_PRESENCE_SNAPSHOT_BYTES

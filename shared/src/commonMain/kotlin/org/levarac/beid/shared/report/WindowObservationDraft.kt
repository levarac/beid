package org.levarac.beid.shared.report

/**
 * The evidence a still-open observation window has accumulated so far.
 *
 * This is a *separate contract* from [UnsentWindowLedger] on purpose. The
 * ledger answers "which windows exist and what state is each in" — the
 * sensing/session state. This answers "what did the device actually observe
 * inside the window that is open right now". Restoring one says nothing
 * about the other: a ledger row with no draft has no recoverable evidence,
 * and a draft with no ledger row is still recoverable evidence. Merging them
 * would let a caller restore BLE/session state and claim, incorrectly, that
 * the proof data came back with it.
 *
 * Native code owns where these bytes live and how they are written; every
 * decision about what a draft may contain, and about its canonical text, is
 * made here so both platforms answer identically.
 *
 * Field validation here is boundary shape only — hexadecimal form, non-empty,
 * bounded length. The exact widths of an RPID, an Event ID and an Event
 * Definition digest are Barnard/parallax protocol semantics (KMP-002) and are
 * decided where the evidence is prepared, not here. A draft is therefore
 * *shaped* input to that preparation, never a second opinion about it.
 */
public class WindowObservationDraft internal constructor(
    internal val state: DraftState,
) {
    public val windowId: String
        get() = state.windowId

    public val enin: Long
        get() = state.enin

    public val eventCode: String
        get() = state.eventCode

    public val eventIdHex: String
        get() = state.eventIdHex

    public val eventDefinitionDigestHex: String
        get() = state.eventDefinitionDigestHex

    public val participantCommitmentHex: String?
        get() = state.participantCommitmentHex

    public val reporterRpidHex: String
        get() = state.reporterRpidHex

    public val observedRpidCount: Int
        get() = state.observedRpidHexes.size

    public fun observedRpidAt(index: Int): String? =
        state.observedRpidHexes.getOrNull(index)
}

/** Result wrapper mirroring [UnsentWindowLedgerLoadResult]; a rejected draft is never a blank one. */
public class WindowObservationDraftResult internal constructor(
    public val draft: WindowObservationDraft?,
    public val isSuccess: Boolean,
    public val errorCode: String?,
)

internal data class DraftState(
    val windowId: String,
    val enin: Long,
    val eventCode: String,
    val eventIdHex: String,
    val eventDefinitionDigestHex: String,
    val participantCommitmentHex: String?,
    val reporterRpidHex: String,
    val observedRpidHexes: List<String> = emptyList(),
)

/**
 * One ENIN window on one device. 10,000 distinct peers inside a single window
 * is already far past any plausible venue, and at roughly 40 bytes per
 * encoded RPID line it keeps the canonical snapshot under
 * [MAX_DRAFT_SNAPSHOT_BYTES] with an order of magnitude to spare.
 */
internal const val MAX_DRAFT_OBSERVED_RPID_COUNT = 10_000
internal const val MAX_DRAFT_SNAPSHOT_BYTES = 1024 * 1024
internal const val MAX_DRAFT_HEX_FIELD_LENGTH = 4 * 1024

public fun createWindowObservationDraft(
    windowId: String,
    enin: Long,
    eventCode: String,
    eventIdHex: String,
    eventDefinitionDigestHex: String,
    participantCommitmentHex: String?,
    reporterRpidHex: String,
): WindowObservationDraftResult {
    if (!windowId.isValidDraftTextField()) {
        return draftFailure("invalid_window_id")
    }
    if (enin < 0L) {
        return draftFailure("invalid_enin")
    }
    if (!eventCode.isValidDraftTextField()) {
        return draftFailure("invalid_event_code")
    }
    if (!eventIdHex.isValidDraftHexField()) {
        return draftFailure("invalid_event_id")
    }
    if (!eventDefinitionDigestHex.isValidDraftHexField()) {
        return draftFailure("invalid_event_definition_digest")
    }
    if (participantCommitmentHex != null && !participantCommitmentHex.isValidDraftHexField()) {
        return draftFailure("invalid_participant_commitment")
    }
    if (!reporterRpidHex.isValidDraftHexField()) {
        return draftFailure("invalid_reporter_rpid")
    }

    return WindowObservationDraftResult(
        draft = WindowObservationDraft(
            DraftState(
                windowId = windowId,
                enin = enin,
                eventCode = eventCode,
                eventIdHex = eventIdHex,
                eventDefinitionDigestHex = eventDefinitionDigestHex,
                participantCommitmentHex = participantCommitmentHex,
                reporterRpidHex = reporterRpidHex,
            ),
        ),
        isSuccess = true,
        errorCode = null,
    )
}

/**
 * Appends one observed RPID, preserving the order in which the device saw
 * them. Re-adding an RPID already present succeeds and changes nothing, so a
 * repeated detection of the same peer is not a failure; the set is what the
 * evidence is about. A duplicate would additionally be rejected downstream
 * when the observation is prepared, which is why it must not reach there.
 */
public fun addWindowObservationDraftRpid(
    draft: WindowObservationDraft,
    observedRpidHex: String,
): WindowObservationDraftResult {
    if (!observedRpidHex.isValidDraftHexField()) {
        return draftFailure("invalid_observed_rpid")
    }
    if (draft.state.observedRpidHexes.contains(observedRpidHex)) {
        return WindowObservationDraftResult(draft = draft, isSuccess = true, errorCode = null)
    }
    if (draft.state.observedRpidHexes.size >= MAX_DRAFT_OBSERVED_RPID_COUNT) {
        return draftFailure("draft_capacity_exceeded")
    }
    return WindowObservationDraftResult(
        draft = WindowObservationDraft(
            draft.state.copy(
                observedRpidHexes = draft.state.observedRpidHexes + observedRpidHex,
            ),
        ),
        isSuccess = true,
        errorCode = null,
    )
}

internal fun draftFailure(errorCode: String): WindowObservationDraftResult =
    WindowObservationDraftResult(draft = null, isSuccess = false, errorCode = errorCode)

internal fun String.isValidDraftTextField(): Boolean {
    if (isEmpty()) {
        return false
    }
    return try {
        encodeToByteArray(throwOnInvalidSequence = true).size <= MAX_LEDGER_TEXT_FIELD_BYTES
    } catch (_: Exception) {
        false
    }
}

internal fun String.isValidDraftHexField(): Boolean =
    isNotEmpty() &&
        length % 2 == 0 &&
        length <= MAX_DRAFT_HEX_FIELD_LENGTH &&
        all { it in '0'..'9' || it in 'a'..'f' }

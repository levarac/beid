package org.levarac.beid.persistence

/**
 * Native-only durable record for one unsent-window artifact's submission
 * bookkeeping, keyed by [windowId] — a sibling to the shared ledger
 * (`UnsentWindowLedger.kt`), not a replacement for any part of it.
 *
 * The shared ledger decides which windows are eligible to become a
 * submission and tracks that submission's lifecycle
 * (in-flight/retryable/acknowledged). It has no opinion on *which operator
 * configuration* a submission POSTs under, because that configuration is not
 * a shared decision — it comes from whichever verified Event Definition this
 * device's own registry read resolved (beid#525's design decision: "never
 * submit an artifact under a different event's configuration").
 *
 * [eventIdHex] is always present — it comes from the window's own
 * [org.levarac.beid.sensing.WindowObservationContext], not from a verified
 * Event Definition, so it survives even when nothing else does. It is what
 * lets the drain resolve a configuration *later* (a fresh registry lookup by
 * event id) for a window whose join-time context carried no verified
 * definition at all — the nearby-card-tap join path.
 *
 * [submissionEndpoint] and its siblings are null exactly when
 * [unresolvedReason] is non-null: this device had no verified Event
 * Definition to derive a configuration from when the window opened (or, once
 * resolved by a later registry lookup, has one now — see
 * [org.levarac.beid.sensing.WindowObservationSubmissionDrain]). A held
 * artifact keeps its record around ([unresolvedReason] set, everything else
 * but [eventIdHex] null) rather than being deleted, so the reason survives
 * for diagnosis.
 *
 * [acceptanceReceiptHex] is the reference persisted before
 * `recordUnsentWindowSubmissionAcceptance` is ever called, per beid#525's
 * crash-safety requirement: the receipt must be durable before the ledger is
 * told about it, never after.
 */
internal data class SubmissionRecord(
    val windowId: String,
    val eventIdHex: String,
    val submissionEndpoint: String?,
    val receiptPublicKeyHex: String?,
    val operatorIdHex: String?,
    val eventDefinitionDigestHex: String?,
    val validFrom: Long?,
    val validUntil: Long?,
    val unresolvedReason: String?,
    val acceptanceReceiptHex: String? = null,
    val terminalErrorCode: String? = null,
    val observationDigestHex: String? = null,
) {
    init {
        require((submissionEndpoint == null) == (unresolvedReason != null)) {
            "A submission record must carry either a configuration or a reason it is missing, not both or neither"
        }
    }
}

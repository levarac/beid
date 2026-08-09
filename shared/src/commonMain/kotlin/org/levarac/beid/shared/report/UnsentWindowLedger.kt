package org.levarac.beid.shared.report

/**
 * Opaque shared state for unsent observation windows.
 *
 * Native callers persist snapshots and perform I/O; all ledger decisions stay
 * behind the top-level reducer functions in this package.
 */
public class UnsentWindowLedger internal constructor(
    internal val state: LedgerState,
)

/**
 * A reducer result with only concrete Swift-exportable properties.
 *
 * `changed` means that native storage must persist `snapshotText`; it does
 * not mean that `ledger` is identical when false. Persistence confirmation
 * and one-shot submission emission intentionally return `changed == false`
 * while advancing in-memory `durableRevision` or
 * `lastEmittedReportRevision`. Every successful caller must therefore adopt
 * the returned `ledger`, including the no-write path.
 */
public class UnsentWindowLedgerTransition internal constructor(
    public val ledger: UnsentWindowLedger,
    public val isSuccess: Boolean,
    public val changed: Boolean,
    public val persistenceRevision: Long,
    public val snapshotText: String?,
    public val submission: UnsentWindowSubmission?,
    public val errorCode: String?,
)

/**
 * A durable submission instruction.
 *
 * Canonical report payload construction is deferred to its facilitator-spec
 * slice (beid#108); this ledger neither defines those bytes nor makes native
 * authoritative.
 */
public class UnsentWindowSubmission internal constructor(
    public val submissionKey: String,
    public val attempt: Int,
    internal val windowIds: List<String>,
    internal val observationReferences: List<String>,
) {
    public val windowCount: Int
        get() = windowIds.size

    public fun windowIdAt(index: Int): String? = windowIds.getOrNull(index)

    public fun observationReferenceAt(index: Int): String? =
        observationReferences.getOrNull(index)
}

/** Result wrapper used by creation and, later, snapshot decoding. */
public class UnsentWindowLedgerLoadResult internal constructor(
    public val ledger: UnsentWindowLedger?,
    public val isSuccess: Boolean,
    public val persistenceRevision: Long,
    public val errorCode: String?,
)

/** Swift-exportable builder for the complete durable observation set at relaunch. */
public class UnsentWindowObservationRecoveryInput internal constructor(
    internal val observations: MutableMap<String, String> = mutableMapOf(),
) {
    public val observationCount: Int
        get() = observations.size
}

internal data class LedgerState(
    val ledgerInstanceIdHex: String,
    val revision: Long = 0L,
    val durableRevision: Long = 0L,
    val nextWindowSequence: Long = 1L,
    val nextReportSequence: Long = 1L,
    val windows: List<LedgerWindow> = emptyList(),
    val reports: List<LedgerReport> = emptyList(),
    val lastEmittedReportRevision: Long? = null,
)

internal data class LedgerWindow(
    val windowId: String,
    val openedSequence: Long,
    val closedRevision: Long? = null,
    val observationReference: String? = null,
    val reportKey: String? = null,
)

internal data class LedgerReport(
    val submissionKey: String,
    val updatedRevision: Long,
    val attempt: Int,
    val windowIds: List<String>,
    val status: LedgerReportStatus = LedgerReportStatus.IN_FLIGHT,
    val retryNotBeforeEpochMilliseconds: Long? = null,
    val acceptanceReceiptReference: String? = null,
    val inclusionReceiptReference: String? = null,
)

internal enum class LedgerReportStatus {
    IN_FLIGHT,
    RETRYABLE_FAILED,
    ACKNOWLEDGED,
}

private val LEDGER_INSTANCE_ID = Regex("[0-9a-f]{32}")

public fun createUnsentWindowLedger(
    ledgerInstanceIdHex: String,
): UnsentWindowLedgerLoadResult {
    if (!LEDGER_INSTANCE_ID.matches(ledgerInstanceIdHex)) {
        return UnsentWindowLedgerLoadResult(
            ledger = null,
            isSuccess = false,
            persistenceRevision = 0L,
            errorCode = "invalid_ledger_instance_id",
        )
    }

    return UnsentWindowLedgerLoadResult(
        ledger = UnsentWindowLedger(
            state = LedgerState(ledgerInstanceIdHex = ledgerInstanceIdHex),
        ),
        isSuccess = true,
        persistenceRevision = 0L,
        errorCode = null,
    )
}

public fun openUnsentWindow(
    ledger: UnsentWindowLedger,
    windowId: String,
): UnsentWindowLedgerTransition {
    if (!windowId.isValidLedgerTextField()) {
        return ledger.failure("invalid_window_id")
    }
    if (ledger.state.windows.size >= MAX_LEDGER_RECORD_COUNT) {
        return ledger.failure("ledger_capacity_exceeded")
    }
    if (ledger.state.windows.any { it.windowId == windowId }) {
        return ledger.failure("duplicate_window_id")
    }

    val revision = ledger.state.revision.incrementRevisionOrNull()
        ?: return ledger.failure("ledger_capacity_exceeded")
    val nextWindowSequence = ledger.state.nextWindowSequence.incrementOrNull()
        ?: return ledger.failure("ledger_capacity_exceeded")
    val updated = ledger.state.copy(
        revision = revision,
        nextWindowSequence = nextWindowSequence,
        windows = ledger.state.windows + LedgerWindow(
            windowId = windowId,
            openedSequence = ledger.state.nextWindowSequence,
        ),
    )
    return ledger.persistenceRequired(updated)
}

public fun closeUnsentWindow(
    ledger: UnsentWindowLedger,
    windowId: String,
    persistedObservationReference: String,
): UnsentWindowLedgerTransition {
    if (!persistedObservationReference.isValidLedgerTextField()) {
        return ledger.failure("invalid_observation_reference")
    }
    val window = ledger.state.windows.firstOrNull { it.windowId == windowId }
        ?: return ledger.failure("unknown_window_id")
    if (window.closedRevision != null) {
        return if (window.observationReference == persistedObservationReference) {
            ledger.unchanged()
        } else {
            ledger.failure("observation_reference_conflict")
        }
    }

    val revision = ledger.state.revision.incrementRevisionOrNull()
        ?: return ledger.failure("ledger_capacity_exceeded")
    val updated = ledger.state.copy(
        revision = revision,
        windows = ledger.state.windows.map {
            if (it.windowId == windowId) {
                it.copy(
                    closedRevision = revision,
                    observationReference = persistedObservationReference,
                )
            } else {
                it
            }
        },
    )
    return ledger.persistenceRequired(updated)
}

public fun createUnsentWindowObservationRecoveryInput():
    UnsentWindowObservationRecoveryInput = UnsentWindowObservationRecoveryInput()

/** Adds one native-proven durable artifact without exposing a public collection. */
public fun addPersistedUnsentWindowObservationForRecovery(
    recoveryInput: UnsentWindowObservationRecoveryInput,
    windowId: String,
    persistedObservationReference: String,
): Boolean {
    if (!windowId.isValidLedgerTextField() || !persistedObservationReference.isValidLedgerTextField()) {
        return false
    }
    val existing = recoveryInput.observations[windowId]
    if (existing != null) {
        return existing == persistedObservationReference
    }
    if (recoveryInput.observations.size >= MAX_LEDGER_RECORD_COUNT) {
        return false
    }
    recoveryInput.observations[windowId] = persistedObservationReference
    return true
}

/**
 * Atomically reconciles the complete durable artifact set after relaunch.
 * Matching open windows close, unmatched open windows are discarded because
 * their in-memory observations died with the process, artifacts with no
 * matching `LedgerWindow` at all are adopted as already-closed windows
 * instead of being ignored, and conflicts with already-closed windows fail
 * closed.
 */
public fun reconcileUnsentWindowLedgerAfterRelaunch(
    ledger: UnsentWindowLedger,
    recoveryInput: UnsentWindowObservationRecoveryInput,
): UnsentWindowLedgerTransition {
    val conflict = ledger.state.windows.firstOrNull { window ->
        val recoveredReference = recoveryInput.observations[window.windowId]
        window.closedRevision != null &&
            recoveredReference != null &&
            recoveredReference != window.observationReference
    }
    if (conflict != null) {
        return ledger.failure("observation_reference_conflict")
    }
    val existingIds = ledger.state.windows.map { it.windowId }.toHashSet()
    val orphanIds = recoveryInput.observations.keys.filter { it !in existingIds }.sorted()
    if (ledger.state.windows.none { it.closedRevision == null } && orphanIds.isEmpty()) {
        return ledger.unchanged()
    }
    val revision = ledger.state.revision.incrementRevisionOrNull()
        ?: return ledger.failure("ledger_capacity_exceeded")

    val matchedWindows = ledger.state.windows.mapNotNull { window ->
        if (window.closedRevision != null) {
            window
        } else {
            recoveryInput.observations[window.windowId]?.let { reference ->
                window.copy(
                    closedRevision = revision,
                    observationReference = reference,
                )
            }
        }
    }
    if (matchedWindows.size + orphanIds.size > MAX_LEDGER_RECORD_COUNT) {
        return ledger.failure("ledger_capacity_exceeded")
    }
    val synthesizedWindows = orphanIds.mapIndexed { offset, windowId ->
        LedgerWindow(
            windowId = windowId,
            openedSequence = ledger.state.nextWindowSequence + offset,
            closedRevision = revision,
            observationReference = recoveryInput.observations.getValue(windowId),
        )
    }
    val mergedWindows = matchedWindows + synthesizedWindows
    if (mergedWindows.map { it.windowId }.toHashSet().size != mergedWindows.size) {
        // Unreachable given orphanIds is filtered against existingIds above,
        // which itself is built from every existing window (open and
        // closed); kept as an explicit failure rather than assuming the
        // reducer's own invariant holds, per the same discipline as
        // openUnsentWindow's duplicate_window_id check.
        return ledger.failure("duplicate_window_id")
    }
    if (!ledger.reconciledSnapshotFits(recoveryInput, revision, orphanIds)) {
        return ledger.failure("ledger_capacity_exceeded")
    }
    return ledger.persistenceRequired(
        ledger.state.copy(
            revision = revision,
            nextWindowSequence = ledger.state.nextWindowSequence + synthesizedWindows.size,
            windows = mergedWindows,
        ),
    )
}

public fun prepareNextUnsentWindowSubmission(
    ledger: UnsentWindowLedger,
    maximumWindowCount: Int,
    nowEpochMilliseconds: Long,
): UnsentWindowLedgerTransition {
    if (maximumWindowCount <= 0) {
        return ledger.failure("invalid_maximum_window_count")
    }
    if (ledger.state.reports.any { it.updatedRevision > ledger.state.durableRevision }) {
        return ledger.unchanged()
    }

    val activeReport = ledger.state.reports.firstOrNull {
        it.status != LedgerReportStatus.ACKNOWLEDGED
    }
    if (activeReport != null) {
        if (activeReport.updatedRevision > ledger.state.durableRevision) {
            return ledger.unchanged()
        }
        if (activeReport.status == LedgerReportStatus.IN_FLIGHT) {
            return ledger.unchanged()
        }

        val retryNotBefore = activeReport.retryNotBeforeEpochMilliseconds
            ?: return ledger.failure("invalid_retry_state")
        if (nowEpochMilliseconds < retryNotBefore) {
            return ledger.unchanged()
        }

        val revision = ledger.state.revision.incrementRevisionOrNull()
            ?: return ledger.failure("ledger_capacity_exceeded")
        if (activeReport.attempt == Int.MAX_VALUE) {
            return ledger.failure("ledger_capacity_exceeded")
        }
        val updated = ledger.state.copy(
            revision = revision,
            reports = ledger.state.reports.map { report ->
                if (report.submissionKey == activeReport.submissionKey) {
                    report.copy(
                        updatedRevision = revision,
                        attempt = report.attempt + 1,
                        status = LedgerReportStatus.IN_FLIGHT,
                        retryNotBeforeEpochMilliseconds = null,
                    )
                } else {
                    report
                }
            },
        )
        return ledger.persistenceRequired(updated)
    }

    val selected = ledger.state.windows
        .asSequence()
        .filter { window ->
            val closedRevision = window.closedRevision
            closedRevision != null &&
                closedRevision <= ledger.state.durableRevision &&
                window.reportKey == null
        }
        .sortedWith(compareBy<LedgerWindow> { it.closedRevision }.thenBy { it.windowId })
        .take(maximumWindowCount)
        .toList()

    if (selected.isEmpty()) {
        return ledger.unchanged()
    }
    if (ledger.state.reports.size >= MAX_LEDGER_RECORD_COUNT) {
        return ledger.failure("ledger_capacity_exceeded")
    }

    val revision = ledger.state.revision.incrementRevisionOrNull()
        ?: return ledger.failure("ledger_capacity_exceeded")
    val nextReportSequence = ledger.state.nextReportSequence.incrementOrNull()
        ?: return ledger.failure("ledger_capacity_exceeded")
    val submissionKey = ledger.state.ledgerInstanceIdHex +
        ledger.state.nextReportSequence.toString(16).padStart(16, '0')
    val selectedIds = selected.map { it.windowId }
    val selectedIdSet = selectedIds.toHashSet()
    val updated = ledger.state.copy(
        revision = revision,
        nextReportSequence = nextReportSequence,
        windows = ledger.state.windows.map { window ->
            if (window.windowId in selectedIdSet) {
                window.copy(reportKey = submissionKey)
            } else {
                window
            }
        },
        reports = ledger.state.reports + LedgerReport(
            submissionKey = submissionKey,
            updatedRevision = revision,
            attempt = 1,
            windowIds = selectedIds,
        ),
    )
    return ledger.persistenceRequired(updated)
}

public fun markUnsentWindowSubmissionRetryable(
    ledger: UnsentWindowLedger,
    submissionKey: String,
    retryNotBeforeEpochMilliseconds: Long,
): UnsentWindowLedgerTransition {
    if (retryNotBeforeEpochMilliseconds < 0L) {
        return ledger.failure("invalid_retry_not_before")
    }

    val report = ledger.state.reports.firstOrNull {
        it.submissionKey == submissionKey
    } ?: return ledger.failure("unknown_submission_key")
    if (report.status != LedgerReportStatus.IN_FLIGHT) {
        return ledger.failure("submission_not_in_flight")
    }
    if (report.updatedRevision > ledger.state.durableRevision) {
        return ledger.failure("submission_not_durable")
    }

    val revision = ledger.state.revision.incrementRevisionOrNull()
        ?: return ledger.failure("ledger_capacity_exceeded")
    val updated = ledger.state.copy(
        revision = revision,
        reports = ledger.state.reports.map { current ->
            if (current.submissionKey == submissionKey) {
                current.copy(
                    updatedRevision = revision,
                    status = LedgerReportStatus.RETRYABLE_FAILED,
                    retryNotBeforeEpochMilliseconds = retryNotBeforeEpochMilliseconds,
                )
            } else {
                current
            }
        },
    )
    return ledger.persistenceRequired(updated)
}

public fun recordUnsentWindowSubmissionAcceptance(
    ledger: UnsentWindowLedger,
    submissionKey: String,
    persistedAcceptanceReceiptReference: String,
): UnsentWindowLedgerTransition {
    if (!persistedAcceptanceReceiptReference.isValidLedgerTextField()) {
        return ledger.failure("invalid_acceptance_receipt_reference")
    }

    val report = ledger.state.reports.firstOrNull {
        it.submissionKey == submissionKey
    } ?: return ledger.failure("unknown_submission_key")
    if (report.status == LedgerReportStatus.ACKNOWLEDGED) {
        return if (report.acceptanceReceiptReference == persistedAcceptanceReceiptReference) {
            ledger.unchanged()
        } else {
            ledger.failure("acceptance_receipt_conflict")
        }
    }
    if (report.updatedRevision > ledger.state.durableRevision) {
        return ledger.failure("submission_not_durable")
    }

    val revision = ledger.state.revision.incrementRevisionOrNull()
        ?: return ledger.failure("ledger_capacity_exceeded")
    val updated = ledger.state.copy(
        revision = revision,
        reports = ledger.state.reports.map { current ->
            if (current.submissionKey == submissionKey) {
                current.copy(
                    updatedRevision = revision,
                    status = LedgerReportStatus.ACKNOWLEDGED,
                    retryNotBeforeEpochMilliseconds = null,
                    acceptanceReceiptReference = persistedAcceptanceReceiptReference,
                )
            } else {
                current
            }
        },
    )
    return ledger.persistenceRequired(updated)
}

public fun recordUnsentWindowSubmissionInclusion(
    ledger: UnsentWindowLedger,
    submissionKey: String,
    persistedInclusionReceiptReference: String,
): UnsentWindowLedgerTransition {
    if (!persistedInclusionReceiptReference.isValidLedgerTextField()) {
        return ledger.failure("invalid_inclusion_receipt_reference")
    }

    val report = ledger.state.reports.firstOrNull {
        it.submissionKey == submissionKey
    } ?: return ledger.failure("unknown_submission_key")
    if (report.status != LedgerReportStatus.ACKNOWLEDGED) {
        return ledger.failure("submission_not_accepted")
    }
    if (report.updatedRevision > ledger.state.durableRevision) {
        return ledger.failure("submission_not_durable")
    }
    if (report.inclusionReceiptReference != null) {
        return if (report.inclusionReceiptReference == persistedInclusionReceiptReference) {
            ledger.unchanged()
        } else {
            ledger.failure("inclusion_receipt_conflict")
        }
    }

    val revision = ledger.state.revision.incrementRevisionOrNull()
        ?: return ledger.failure("ledger_capacity_exceeded")
    val updated = ledger.state.copy(
        revision = revision,
        reports = ledger.state.reports.map { current ->
            if (current.submissionKey == submissionKey) {
                current.copy(
                    updatedRevision = revision,
                    inclusionReceiptReference = persistedInclusionReceiptReference,
                )
            } else {
                current
            }
        },
    )
    return ledger.persistenceRequired(updated)
}

public fun confirmUnsentWindowLedgerPersistence(
    ledger: UnsentWindowLedger,
    revision: Long,
): UnsentWindowLedgerTransition {
    if (revision <= 0L || revision != ledger.state.revision) {
        return ledger.failure("invalid_persistence_revision")
    }
    if (revision <= ledger.state.durableRevision) {
        return ledger.unchanged()
    }

    return ledger.state
        .copy(durableRevision = revision)
        .emitDurableSubmissionIfNeeded()
}

public fun resumeUnsentWindowSubmissionAfterRestore(
    ledger: UnsentWindowLedger,
): UnsentWindowLedgerTransition = ledger.state.emitDurableSubmissionIfNeeded()

private fun LedgerState.emitDurableSubmissionIfNeeded(): UnsentWindowLedgerTransition {
    val report = reports.firstOrNull {
        it.status == LedgerReportStatus.IN_FLIGHT &&
            it.updatedRevision <= durableRevision &&
            it.updatedRevision != lastEmittedReportRevision
    }
    if (report == null) {
        return UnsentWindowLedger(this).unchanged()
    }

    val emittedState = copy(lastEmittedReportRevision = report.updatedRevision)
    val windowsById = windows.associateBy { it.windowId }
    return UnsentWindowLedgerTransition(
        ledger = UnsentWindowLedger(emittedState),
        isSuccess = true,
        changed = false,
        persistenceRevision = 0L,
        snapshotText = null,
        submission = UnsentWindowSubmission(
            submissionKey = report.submissionKey,
            attempt = report.attempt,
            windowIds = report.windowIds,
            observationReferences = report.windowIds.map { windowId ->
                checkNotNull(windowsById[windowId]?.observationReference)
            },
        ),
        errorCode = null,
    )
}

private fun UnsentWindowLedger.persistenceRequired(
    updated: LedgerState,
): UnsentWindowLedgerTransition {
    val updatedLedger = UnsentWindowLedger(updated)
    val snapshotText = encodeUnsentWindowLedgerSnapshot(updatedLedger)
    if (snapshotText.encodeToByteArray().size > MAX_LEDGER_SNAPSHOT_BYTES) {
        return failure("ledger_capacity_exceeded")
    }

    return UnsentWindowLedgerTransition(
        ledger = updatedLedger,
        isSuccess = true,
        changed = true,
        persistenceRevision = updated.revision,
        snapshotText = snapshotText,
        submission = null,
        errorCode = null,
    )
}

private fun UnsentWindowLedger.unchanged(): UnsentWindowLedgerTransition =
    UnsentWindowLedgerTransition(
        ledger = this,
        isSuccess = true,
        changed = false,
        persistenceRevision = 0L,
        snapshotText = null,
        submission = null,
        errorCode = null,
    )

private fun UnsentWindowLedger.failure(errorCode: String): UnsentWindowLedgerTransition =
    UnsentWindowLedgerTransition(
        ledger = this,
        isSuccess = false,
        changed = false,
        persistenceRevision = 0L,
        snapshotText = null,
        submission = null,
        errorCode = errorCode,
    )

private fun Long.incrementOrNull(): Long? =
    if (this == Long.MAX_VALUE) null else this + 1L

/**
 * The reducer never produces `revision == Long.MAX_VALUE`; every mutating
 * transition uses this instead of the plain [incrementOrNull] for
 * `revision` specifically, so `Long.MAX_VALUE` stays permanently unreachable
 * via normal mutation. [decodeUnsentWindowLedgerSnapshot] relies on that and
 * rejects any snapshot claiming `revision == Long.MAX_VALUE` as invalid —
 * keep both in sync if either changes.
 */
private fun Long.incrementRevisionOrNull(): Long? =
    if (this >= Long.MAX_VALUE - 1L) null else this + 1L

private fun String.isValidLedgerTextField(): Boolean {
    if (isEmpty()) {
        return false
    }
    return try {
        encodeToByteArray(throwOnInvalidSequence = true).size <= MAX_LEDGER_TEXT_FIELD_BYTES
    } catch (_: Exception) {
        false
    }
}

/**
 * Prevents bulk relaunch recovery from allocating an oversized snapshot just
 * to discover the 8 MiB limit afterward. Canonical snapshots are ASCII, so
 * their character count is their UTF-8 byte count.
 */
private fun UnsentWindowLedger.reconciledSnapshotFits(
    recoveryInput: UnsentWindowObservationRecoveryInput,
    revision: Long,
    orphanIds: List<String>,
): Boolean {
    var encodedSize = encodeUnsentWindowLedgerSnapshot(this).length.toLong()
    encodedSize += revision.toString().length - state.revision.toString().length
    val resultingWindowCount = state.windows.count { window ->
        window.closedRevision != null || recoveryInput.observations.containsKey(window.windowId)
    } + orphanIds.size
    encodedSize +=
        resultingWindowCount.toString().length - state.windows.size.toString().length
    val closedRevisionLength = revision.toString().length.toLong()
    state.windows.forEach { window ->
        if (window.closedRevision != null) {
            return@forEach
        }
        val recoveredReference = recoveryInput.observations[window.windowId]
        if (recoveredReference == null) {
            val windowIdBytes = window.windowId
                .encodeToByteArray(throwOnInvalidSequence = true)
                .size
                .toLong()
            encodedSize -=
                "window\t".length +
                (windowIdBytes * 2L) +
                1L +
                window.openedSequence.toString().length +
                1L +
                1L +
                1L +
                1L +
                1L
        } else {
            val referenceBytes = recoveredReference
                .encodeToByteArray(throwOnInvalidSequence = true)
                .size
                .toLong()
            encodedSize += (closedRevisionLength - 1L) + (referenceBytes * 2L - 1L)
        }
    }
    // Synthesized rows have no prior line to diff against — each is a whole
    // new "window\t..." line appended to the snapshot, always already closed
    // (never a bare "-"/"-" tail like a still-open row would encode).
    orphanIds.forEachIndexed { offset, windowId ->
        val windowIdBytes = windowId
            .encodeToByteArray(throwOnInvalidSequence = true)
            .size
            .toLong()
        val openedSequenceLength = (state.nextWindowSequence + offset).toString().length
        val referenceBytes = recoveryInput.observations.getValue(windowId)
            .encodeToByteArray(throwOnInvalidSequence = true)
            .size
            .toLong()
        encodedSize +=
            "window\t".length +
            (windowIdBytes * 2L) +
            1L +
            openedSequenceLength +
            1L +
            closedRevisionLength +
            1L +
            (referenceBytes * 2L) +
            1L
    }
    return encodedSize <= MAX_LEDGER_SNAPSHOT_BYTES.toLong()
}

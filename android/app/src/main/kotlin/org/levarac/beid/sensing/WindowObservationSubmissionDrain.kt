package org.levarac.beid.sensing

import android.util.Log
import org.levarac.beid.persistence.SubmissionRecord
import org.levarac.beid.persistence.SubmissionRecordStore
import org.levarac.beid.shared.report.UnsentWindowSubmission
import org.levarac.parallax.submission.AcceptanceReceipt
import org.levarac.parallax.submission.SubmissionClient
import org.levarac.parallax.submission.SubmissionOperatorConfiguration
import org.levarac.parallax.submission.SubmissionResult
import org.levarac.parallax.submission.createSubmissionOperatorConfigurationWithOperatorId
import org.levarac.parallax.submission.restoreStoredObservation

/**
 * beid#525's drain: the missing half of Android's writer
 * (`WindowObservationAccumulator` → `UnsentWindowLedgerStore`). Signed,
 * durable observations accumulate on disk; this class is what actually POSTs
 * them.
 *
 * Owned one-per-process alongside [WindowObservationAccumulator], sharing its
 * ledger — [WindowObservationRuntimeOwner.acquire] constructs both together.
 * Every ledger-touching call this class makes (via [WindowObservationAccumulator.beginNextSubmissionAttempt],
 * [WindowObservationAccumulator.resumeSubmissionAfterRestore],
 * [WindowObservationAccumulator.completeSubmissionAcceptance],
 * [WindowObservationAccumulator.completeSubmissionRetryable]) is
 * `@Synchronized` on that same accumulator instance, so the ledger mutation
 * that decides "is a submission already in flight" is atomic with the
 * writer's own window open/close — the reducer's own IN_FLIGHT status is
 * what makes a duplicate trigger a safe no-op, not any lock this class holds
 * itself. The lock is never held across the network call below: each
 * `@Synchronized` accumulator method returns before [client] is ever touched,
 * and the completion callback re-enters a fresh `@Synchronized` call to apply
 * the result.
 */
internal class WindowObservationSubmissionDrain(
    private val accumulator: WindowObservationAccumulator,
    private val submissionRecordStore: SubmissionRecordStore,
    private val client: SubmissionClient,
    private val nowEpochMilliseconds: () -> Long,
    private val allowInsecureLoopbackForTests: Boolean = false,
    /**
     * Test-only crash boundary: returning `false` abandons processing right
     * after a verified operator acceptance, before anything about it is
     * persisted — exactly like a process death between the POST completing
     * and the receipt being written. Mirrors iOS's
     * `ReportSubmissionRuntime.receiptPersistenceGate`.
     */
    private val receiptPersistenceGate: () -> Boolean = { true },
) {
    /** beid#525's "after a window's durable close" / "on foreground resume" / "when a retry time arrives" triggers. */
    fun drain() {
        accumulator.beginNextSubmissionAttempt(nowEpochMilliseconds())
            ?.let { handle(it, SubmissionEmissionOrigin.FRESH) }
    }

    /**
     * beid#525's "after startup reconciliation completes" trigger. Must run
     * after [WindowObservationAccumulator.recoverAfterRelaunch], never
     * before — see that method's doc.
     */
    fun resumeAfterRestore() {
        accumulator.resumeSubmissionAfterRestore()?.let { handle(it, SubmissionEmissionOrigin.UNCONFIRMED) }
        // Independent of whatever the line above found: relaunch
        // reconciliation may have made windows durable that were never
        // selected into a report at all before the crash, and those are
        // ordinary fresh work, not a resume.
        drain()
    }

    /** [WindowObservationAccumulator]'s sink for a submission its own writer-side ledger writes coincidentally surfaced. */
    fun receiveEmittedSubmission(submission: UnsentWindowSubmission, origin: SubmissionEmissionOrigin) {
        handle(submission, origin)
    }

    private fun handle(submission: UnsentWindowSubmission, origin: SubmissionEmissionOrigin) {
        val windowId = checkNotNull(submission.windowIdAt(0)) {
            "A submission with maximumWindowCount=1 must name its one window"
        }
        val digestHex = checkNotNull(submission.observationReferenceAt(0)) {
            "A submission with maximumWindowCount=1 must name its one observation reference"
        }

        val record = submissionRecordStore.recordFor(windowId)
        val configuration = record?.let(::restoreConfiguration)
        if (configuration == null) {
            hold(submission.submissionKey, windowId, record?.unresolvedReason ?: "no submission record for window $windowId")
            return
        }

        val storedBytes = accumulator.loadStoredObservationBytes(windowId, digestHex)
        if (storedBytes == null) {
            hold(submission.submissionKey, windowId, "missing durable observation bytes for window $windowId")
            return
        }
        // Never re-signed, never re-derived — beid#525 part 3. This is the
        // exact bytes `closeCurrentWindow` wrote, reloaded and re-verified
        // against the digest the ledger already committed to.
        val restored = restoreStoredObservation(storedBytes.toLowercaseHex())
        if (restored == null || restored.observationDigest.toByteArray().toLowercaseHex() != digestHex) {
            hold(submission.submissionKey, windowId, "stored observation bytes for window $windowId failed digest verification")
            return
        }

        // beid#525 part 4: attempt 1 fresh off `beginNextSubmissionAttempt`
        // has never had a chance to reach the operator in this or any other
        // process. Anything else — a resumed/coincidental emission, or a
        // retry attempt this same process minted after a prior failure —
        // must look up before posting again.
        val lookupFirst = origin == SubmissionEmissionOrigin.UNCONFIRMED || submission.attempt > 1
        if (lookupFirst) {
            client.lookupReceipt(restored, configuration) { result ->
                onLookupResult(result, submission, windowId, restored, configuration)
            }
        } else {
            client.submit(restored, configuration) { result -> onSubmitResult(result, submission, windowId) }
        }
    }

    private fun onLookupResult(
        result: SubmissionResult,
        submission: UnsentWindowSubmission,
        windowId: String,
        restored: org.levarac.parallax.submission.StoredObservationV1,
        configuration: SubmissionOperatorConfiguration,
    ) {
        val receipt = result.receipt
        if (result.isSuccess && receipt != null) {
            acceptAndContinue(receipt, submission, windowId)
            return
        }
        if (result.errorCode == "receipt_not_found") {
            // The only condition that permits sending the same bytes again —
            // beid#525's crash-safety requirement.
            client.submit(restored, configuration) { submitResult -> onSubmitResult(submitResult, submission, windowId) }
            return
        }
        dispatchFailure(result, submission, windowId)
    }

    private fun onSubmitResult(result: SubmissionResult, submission: UnsentWindowSubmission, windowId: String) {
        val receipt = result.receipt
        if (result.isSuccess && receipt != null) {
            if (!receiptPersistenceGate()) {
                // Simulated crash: the operator accepted it, but nothing
                // about that reaches disk from here. The ledger is left
                // exactly as durably IN_FLIGHT as it already was.
                return
            }
            acceptAndContinue(receipt, submission, windowId)
            return
        }
        dispatchFailure(result, submission, windowId)
    }

    /** Persists the receipt's exact bytes FIRST, then tells the ledger — beid#525's ordering requirement. */
    private fun acceptAndContinue(receipt: AcceptanceReceipt, submission: UnsentWindowSubmission, windowId: String) {
        submissionRecordStore.recordAcceptance(windowId, receipt.signedBytes.toByteArray().toLowercaseHex())
        accumulator.completeSubmissionAcceptance(submission.submissionKey, acceptanceReceiptReference = windowId)
        // Acceptance frees the head-of-line slot; check for the next durable window.
        drain()
    }

    private fun dispatchFailure(result: SubmissionResult, submission: UnsentWindowSubmission, windowId: String) {
        if (result.isRetryable) {
            accumulator.completeSubmissionRetryable(
                submission.submissionKey,
                retryNotBeforeEpochMilliseconds = nowEpochMilliseconds() + RETRY_BACKOFF_MILLIS,
            )
            logSubmissionOutcome("scheduled retry for window $windowId: ${result.errorCode}")
        } else {
            accumulator.completeSubmissionRetryable(submission.submissionKey, retryNotBeforeEpochMilliseconds = Long.MAX_VALUE)
            submissionRecordStore.recordTerminalFailure(windowId, result.errorCode ?: "submission_failed")
            logSubmissionOutcome("stopped automatic submission for window $windowId: ${result.errorCode}")
        }
        // Terminal or not-yet-due-retryable: the head-of-line slot stays
        // occupied. No chained `drain()` call — beid#525's honest
        // head-of-line-blocking behavior, stated in the PR description.
    }

    /** An artifact whose configuration or stored bytes cannot be trusted is held, never guessed at — beid#525 part 2. */
    private fun hold(submissionKey: String, windowId: String, reason: String) {
        accumulator.completeSubmissionRetryable(submissionKey, retryNotBeforeEpochMilliseconds = Long.MAX_VALUE)
        submissionRecordStore.recordTerminalFailure(windowId, "invalid_configuration")
        logSubmissionOutcome("held window $windowId: $reason")
    }

    private fun restoreConfiguration(record: SubmissionRecord): SubmissionOperatorConfiguration? {
        val endpoint = record.submissionEndpoint ?: return null
        val receiptPublicKeyHex = record.receiptPublicKeyHex ?: return null
        return createSubmissionOperatorConfigurationWithOperatorId(
            endpoint = endpoint,
            receiptPublicKeyHex = receiptPublicKeyHex,
            operatorIdHex = record.operatorIdHex,
            eventIdHex = record.eventIdHex,
            eventDefinitionDigestHex = record.eventDefinitionDigestHex,
            validFrom = record.validFrom,
            validUntil = record.validUntil,
            allowInsecureLoopbackForTests = allowInsecureLoopbackForTests,
        )
    }

    private fun logSubmissionOutcome(message: String) {
        try {
            Log.w(TAG, message)
        } catch (_: RuntimeException) {
            // No logger available (plain JVM test) — nothing to report it to.
        }
    }

    private companion object {
        const val TAG = "BeidSubmissionDrain"

        /**
         * Fixed backoff for a retryable failure (TIMEOUT/RATE_LIMITED/
         * SERVER_ERROR). beid#525 does not specify a backoff policy beyond
         * "never retry forever" for terminal failures; a constant is the
         * simplest thing that satisfies "stop and surface the reason" for
         * the retryable case without inventing an untested exponential
         * schedule this issue does not ask for.
         */
        const val RETRY_BACKOFF_MILLIS = 30_000L
    }
}

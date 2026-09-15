package org.levarac.beid.sensing

import android.util.Log
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import org.levarac.beid.persistence.SubmissionRecord
import org.levarac.beid.persistence.SubmissionRecordStore
import org.levarac.beid.shared.report.UnsentWindowSubmission
import org.levarac.parallax.submission.AcceptanceReceipt
import org.levarac.parallax.submission.SubmissionClient
import org.levarac.parallax.submission.SubmissionOperatorConfiguration
import org.levarac.parallax.submission.SubmissionResult
import org.levarac.parallax.submission.createSubmissionOperatorConfigurationWithOperatorId
import org.levarac.parallax.submission.restoreStoredObservation

/** Preserves whether a registry lookup produced usable evidence, failed transiently, or failed closed. */
internal sealed interface SubmissionConfigurationResolution {
    data class Resolved(val configuration: SubmissionOperatorConfiguration) : SubmissionConfigurationResolution

    data class RetryableFailure(val errorCode: String?) : SubmissionConfigurationResolution

    data class PermanentlyUnusable(val errorCode: String?) : SubmissionConfigurationResolution
}

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
    /**
     * A fresh, independent way to resolve a configuration by event id when
     * the window's own persisted record has none — beid#525's nearby-join
     * gap. A missing resolver means "no such capability". A present resolver
     * must keep a transient registry outage separate from permanently
     * unusable evidence so the durable head report is not held forever.
     *
     * Shaped around [SubmissionOperatorConfiguration] rather than the
     * shared module's `EventDefinitionContext`/`EventDefinitionResolution`
     * on purpose: both of those have `internal` constructors in `:shared`
     * and cannot be faked from `:app` tests, exactly the constraint that
     * shaped iOS's own `EventDefinitionContextProvider` /
     * `VerifiedSubmissionDefinition` seam
     * (`ios/Beid/Sensing/ReportSubmissionRuntime.swift`). Production wires
     * this to a real registry read (`WindowObservationRuntimeOwner.acquire`);
     * a test can inject a fake that returns a configuration built with the
     * public `createSubmissionOperatorConfiguration(...)` factory.
     */
    private val configurationResolver: SubmissionConfigurationResolver? = null,
    private val retryScheduler: RetryScheduler? = null,
) {
    @Volatile private var closed = false
    private var scheduledRetry: RetryHandle? = null

    /** See [WindowObservationSubmissionDrain]'s `configurationResolver` doc. */
    fun interface SubmissionConfigurationResolver {
        fun resolve(eventIdHex: String, completion: (SubmissionConfigurationResolution) -> Unit)
    }

    fun interface RetryHandle { fun cancel() }

    fun interface RetryScheduler {
        fun schedule(delayMillis: Long, task: () -> Unit): RetryHandle

        fun close() = Unit
    }

    /** beid#525's "after a window's durable close" / "on foreground resume" / "when a retry time arrives" triggers. */
    fun drain() {
        if (closed) return
        scheduledRetry = null
        accumulator.beginNextSubmissionAttempt(nowEpochMilliseconds())
            ?.let { handle(it, SubmissionEmissionOrigin.FRESH) }
    }

    fun close() {
        closed = true
        scheduledRetry?.cancel()
        scheduledRetry = null
        retryScheduler?.close()
    }

    /**
     * beid#525's "after startup reconciliation completes" trigger. Must run
     * after [WindowObservationAccumulator.recoverAfterRelaunch], never
     * before — see that method's doc.
     */
    fun resumeAfterRestore() {
        accumulator.resumeSubmissionAfterRestore()?.let { handle(it, SubmissionEmissionOrigin.UNCONFIRMED) }
        scheduleRestoredRetryIfNeeded()
        // Independent of whatever the line above found: relaunch
        // reconciliation may have made windows durable that were never
        // selected into a report at all before the crash, and those are
        // ordinary fresh work, not a resume.
        drain()
    }

    private fun scheduleRestoredRetryIfNeeded() {
        val deadline = accumulator.retryNotBeforeEpochMilliseconds() ?: return
        if (deadline == Long.MAX_VALUE || closed) return
        val delay = (deadline - nowEpochMilliseconds()).coerceAtLeast(0L)
        scheduledRetry?.cancel()
        scheduledRetry = retryScheduler?.schedule(delay) { drain() }
    }

    /** [WindowObservationAccumulator]'s sink for a submission its own writer-side ledger writes coincidentally surfaced. */
    fun receiveEmittedSubmission(submission: UnsentWindowSubmission, origin: SubmissionEmissionOrigin) {
        if (closed) return
        handle(submission, origin)
    }

    private fun handle(submission: UnsentWindowSubmission, origin: SubmissionEmissionOrigin) {
        val windowId = checkNotNull(submission.windowIdAt(0)) {
            "A submission with maximumWindowCount=1 must name its one window"
        }
        val digestHex = checkNotNull(submission.observationReferenceAt(0)) {
            "A submission with maximumWindowCount=1 must name its one observation reference"
        }
        submissionRecordStore.recordObservationDigest(windowId, digestHex)

        val record = submissionRecordStore.recordFor(windowId)
        val configuration = record?.let(::restoreConfiguration)
        if (configuration != null) {
            proceedWithConfiguration(submission, origin, windowId, digestHex, configuration)
            return
        }

        val eventIdHex = record?.eventIdHex
        val resolver = configurationResolver
        if (eventIdHex == null || resolver == null) {
            hold(submission.submissionKey, windowId, record?.unresolvedReason ?: "no submission record for window $windowId")
            return
        }
        // beid#525's nearby-join gap: this window's own join-time context
        // carried no verified Event Definition. A fresh, independent
        // registry lookup by event id — exactly the pattern iOS's
        // `ReportSubmissionRuntime` always uses, regardless of how the event
        // was joined — is the only other legitimate source of a
        // configuration. Never fall back to any other event's configuration
        // if this fails.
        resolver.resolve(eventIdHex) { resolution ->
            when (resolution) {
                is SubmissionConfigurationResolution.RetryableFailure -> {
                    accumulator.completeSubmissionRetryable(
                        submission.submissionKey,
                        retryNotBeforeEpochMilliseconds = nowEpochMilliseconds() + RETRY_BACKOFF_MILLIS,
                    )
                    logSubmissionOutcome("scheduled registry retry for window $windowId: ${resolution.errorCode}")
                    scheduleRetry()
                }

                is SubmissionConfigurationResolution.PermanentlyUnusable -> {
                    hold(
                        submission.submissionKey,
                        windowId,
                        "registry lookup for event $eventIdHex produced no usable Event Definition: ${resolution.errorCode}",
                    )
                }

                is SubmissionConfigurationResolution.Resolved -> {
                    val resolved = resolution.configuration
                    if (!persistSubmissionRecord(submission.submissionKey, windowId, "configuration") {
                        submissionRecordStore.recordResolvedConfiguration(
                            windowId = windowId,
                            submissionEndpoint = resolved.submissionEndpoint,
                            receiptPublicKeyHex = resolved.receiptPublicKey.toByteArray().toLowercaseHex(),
                            operatorIdHex = resolved.operatorId.toByteArray().toLowercaseHex(),
                            eventDefinitionDigestHex = resolved.eventDefinitionDigest?.toByteArray()?.toLowercaseHex(),
                            validFrom = resolved.validFrom,
                            validUntil = resolved.validUntil,
                        )
                    }) return@resolve
                    proceedWithConfiguration(submission, origin, windowId, digestHex, resolved)
                }
            }
        }
    }

    private fun proceedWithConfiguration(
        submission: UnsentWindowSubmission,
        origin: SubmissionEmissionOrigin,
        windowId: String,
        digestHex: String,
        configuration: SubmissionOperatorConfiguration,
    ) {
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
        if (!persistSubmissionRecord(submission.submissionKey, windowId, "acceptance") {
            submissionRecordStore.recordAcceptance(windowId, receipt.signedBytes.toByteArray().toLowercaseHex())
        }) return
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
            scheduleRetry()
        } else {
            if (!persistSubmissionRecord(submission.submissionKey, windowId, "terminal_failure") {
                submissionRecordStore.recordTerminalFailure(windowId, result.errorCode ?: "submission_failed")
            }) return
            accumulator.completeSubmissionRetryable(submission.submissionKey, retryNotBeforeEpochMilliseconds = Long.MAX_VALUE)
            logSubmissionOutcome("stopped automatic submission for window $windowId: ${result.errorCode}")
        }
        // Terminal or not-yet-due-retryable: the head-of-line slot stays
        // occupied. No chained `drain()` call — beid#525's honest
        // head-of-line-blocking behavior, stated in the PR description.
    }

    /** An artifact whose configuration or stored bytes cannot be trusted is held, never guessed at — beid#525 part 2. */
    private fun hold(submissionKey: String, windowId: String, reason: String) {
        if (!persistSubmissionRecord(submissionKey, windowId, "hold") {
            submissionRecordStore.recordTerminalFailure(windowId, "invalid_configuration")
        }) return
        accumulator.completeSubmissionRetryable(submissionKey, retryNotBeforeEpochMilliseconds = Long.MAX_VALUE)
        logSubmissionOutcome("held window $windowId: $reason")
    }

    /** Missing/suspended records and disk failures cannot stand in for a durable write. */
    private fun persistSubmissionRecord(
        submissionKey: String,
        windowId: String,
        operation: String,
        write: () -> Boolean,
    ): Boolean {
        val persisted = try {
            write()
        } catch (_: IOException) {
            false
        }
        if (persisted) return true
        val detail = if (submissionRecordStore.recordFor(windowId) == null) {
            "record_missing"
        } else {
            "write_failed"
        }
        logSubmissionOutcome("record_persistence_failed operation=$operation detail=$detail window=$windowId")
        // Keep the report unacknowledged. A later attempt performs receipt
        // lookup before posting, including when the operator already accepted
        // the bytes whose receipt could not be saved locally.
        accumulator.completeSubmissionRetryable(
            submissionKey,
            retryNotBeforeEpochMilliseconds = nowEpochMilliseconds() + RETRY_BACKOFF_MILLIS,
        )
        scheduleRetry()
        return false
    }

    private fun scheduleRetry(delayMillis: Long = RETRY_BACKOFF_MILLIS) {
        if (closed) return
        val scheduler = retryScheduler ?: return
        scheduledRetry?.cancel()
        scheduledRetry = scheduler.schedule(delayMillis) { drain() }
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

/** Process-scoped timer used by the Android runtime; daemon thread avoids pinning test JVMs. */
internal class DefaultSubmissionRetryScheduler : WindowObservationSubmissionDrain.RetryScheduler {
    private val executor = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "beid-submission-retry").apply { isDaemon = true }
    }

    override fun schedule(delayMillis: Long, task: () -> Unit): WindowObservationSubmissionDrain.RetryHandle {
        val future: ScheduledFuture<*> = executor.schedule(task, delayMillis, TimeUnit.MILLISECONDS)
        return WindowObservationSubmissionDrain.RetryHandle { future.cancel(false) }
    }

    override fun close() {
        executor.shutdownNow()
    }
}

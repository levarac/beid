package org.levarac.beid.sensing

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import org.levarac.beid.persistence.SubmissionRecord
import org.levarac.beid.persistence.SubmissionRecordStore
import org.levarac.beid.persistence.UnsentWindowLedgerStore
import org.levarac.beid.persistence.WindowObservationDraftStore
import org.levarac.beid.shared.report.UnsentWindowLedger
import org.levarac.beid.shared.report.UnsentWindowSubmission
import org.levarac.beid.shared.report.addPersistedUnsentWindowObservationForRecovery
import org.levarac.beid.shared.report.addWindowObservationDraftRpid
import org.levarac.beid.shared.report.closeUnsentWindow
import org.levarac.beid.shared.report.confirmUnsentWindowLedgerPersistence
import org.levarac.beid.shared.report.createUnsentWindowObservationRecoveryInput
import org.levarac.beid.shared.report.createUnsentWindowLedger
import org.levarac.beid.shared.report.createWindowObservationDraft
import org.levarac.beid.shared.report.markUnsentWindowSubmissionRetryable
import org.levarac.beid.shared.report.openUnsentWindow
import org.levarac.beid.shared.report.prepareNextUnsentWindowSubmission
import org.levarac.beid.shared.report.reconcileUnsentWindowLedgerAfterRelaunch
import org.levarac.beid.shared.report.recordUnsentWindowSubmissionAcceptance
import org.levarac.beid.shared.report.resumeUnsentWindowSubmissionAfterRestore
import org.levarac.parallax.observation.ObservationPreparationResult
import org.levarac.parallax.observation.PreparedObservationV1
import org.levarac.parallax.observation.createMutualSensingWindowEvidence
import org.levarac.parallax.observation.prepareMutualSensingObservation
import org.levarac.parallax.submission.SubmissionOperatorConfiguration
import org.levarac.parallax.submission.restoreStoredObservation
import org.levarac.parallax.submission.storeSignedObservation

internal data class WindowObservationContext(
    val eventCode: String,
    val eventIdHex: String,
    val eventDefinitionDigestHex: String,
    val participantCommitmentHex: String? = null,
    /**
     * The submission configuration this window's artifact must POST under,
     * derived once at join time from a verified Event Definition — beid#525.
     * `null` when no verified definition was available (the nearby-card-tap
     * join path today; see `docs/checkpoints/android-submission-drain.md`),
     * in which case the artifact this window produces is held rather than
     * guessed at, per beid#525's design decision: never submit under a
     * different event's configuration, and never fall back to whatever
     * event happens to be currently joined.
     */
    val submissionConfiguration: SubmissionOperatorConfiguration? = null,
)

/**
 * Distinguishes a submission emission this process can prove was never
 * POSTed from one it cannot.
 *
 * [FRESH] comes from [WindowObservationAccumulator.beginNextSubmissionAttempt]
 * emitting an attempt it just durably confirmed, in this exact call, on this
 * live process — nothing has had a chance to POST it yet. Every other
 * emission — after a relaunch
 * ([WindowObservationAccumulator.resumeSubmissionAfterRestore]), or the
 * writer's own ledger writes coincidentally surfacing one via
 * `confirmUnsentWindowLedgerPersistence`'s always-run emission check — cannot
 * make that claim, so they are [UNCONFIRMED]. beid#525's crash-safety
 * requirement ("on retry or after restore, look up before posting again")
 * is what this distinction exists to serve; see
 * [WindowObservationSubmissionDrain].
 */
internal enum class SubmissionEmissionOrigin { FRESH, UNCONFIRMED }

internal class WindowObservationContextState {
    var value: WindowObservationContext? = null
}

internal class WindowObservationRuntime internal constructor(
    val accumulator: WindowObservationAccumulator,
    val submissionDrain: WindowObservationSubmissionDrain,
    private val contextState: WindowObservationContextState,
) {
    fun updateContext(context: WindowObservationContext?) {
        contextState.value = context
    }

    fun beginEvent(eventCode: String): Boolean = accumulator.beginEvent(eventCode)

    /**
     * Runs the relaunch recovery this runtime's storage is owed. Callers must
     * invoke it off the main thread; see
     * [WindowObservationAccumulator.recoverAfterRelaunch].
     *
     * Resuming the submission drain runs strictly after reconciliation
     * finishes, never before: `reconcileDurableArtifactsAfterRelaunch`'s own
     * ledger write can itself durably confirm a report and — per
     * [SubmissionEmissionOrigin]'s doc — hand this same submission to the
     * drain first, via [WindowObservationAccumulator]'s emission callback.
     * [WindowObservationSubmissionDrain.resumeAfterRestore] only has
     * anything left to find when that did not already happen.
     */
    fun recoverAfterRelaunch() {
        accumulator.recoverAfterRelaunch()
        submissionDrain.resumeAfterRestore()
    }

    /** Triggers the submission drain for whatever the ledger already has queued — beid#525's "after a window's durable close" / "on foreground resume" triggers. */
    fun drainPendingSubmissions() {
        submissionDrain.drain()
    }
}

/** Owns the Activity-independent open-window runtime for one Android process. */
internal class WindowObservationRuntimeOwner(
    private val newWindowId: () -> UUID = UUID::randomUUID,
    private val ledgerInstanceId: () -> String = { UUID.randomUUID().toHex() },
) {
    private var activeRuntime: WindowObservationRuntime? = null
    private var activeFilesPath: String? = null

    @Synchronized
    fun acquire(
        filesDir: File,
        cryptography: SensingCryptography,
        nowEpochSeconds: () -> Double,
        submissionClient: org.levarac.parallax.submission.SubmissionClient =
            org.levarac.parallax.submission.createSubmissionClient(),
        /**
         * beid#525's nearby-join gap: when a window's join-time context
         * carried no verified Event Definition (the nearby-card-tap join
         * path), the drain resolves one fresh, by event id, through this
         * same registry seam [EventJoinCoordinator] already holds for its
         * own join gate. `null` means no such capability — every affected
         * artifact stays held.
         */
        eventJoinRegistry: EventJoinRegistry? = null,
    ): WindowObservationRuntime {
        val filesPath = filesDir.toPath().toAbsolutePath().normalize().toString()
        activeRuntime?.let { runtime ->
            check(activeFilesPath == filesPath) { "Window observation runtime cannot change storage roots" }
            return runtime
        }
        val contextState = WindowObservationContextState()
        val observationDirectory = File(filesDir, "canonical-observations-v1")
        val submissionRecordStore = SubmissionRecordStore(SubmissionRecordStore.defaultFile(filesDir))
        lateinit var drain: WindowObservationSubmissionDrain
        val accumulator = WindowObservationAccumulator(
            context = { contextState.value },
            cryptography = cryptography,
            ledgerStore = UnsentWindowLedgerStore.recoveringCorruptSnapshot(
                UnsentWindowLedgerStore.defaultFile(filesDir),
            ).store,
            draftStore = WindowObservationDraftStore(
                WindowObservationDraftStore.defaultFile(filesDir),
            ),
            submissionRecordStore = submissionRecordStore,
            observationDirectory = observationDirectory,
            nowEpochSeconds = nowEpochSeconds,
            newWindowId = newWindowId,
            ledgerInstanceId = ledgerInstanceId,
            // The writer's own ledger writes (open/close/relaunch reconcile)
            // can coincidentally durably-confirm a submission before the
            // drain ever asks for one — see [SubmissionEmissionOrigin]'s doc.
            // `drain` is assigned below, before this lambda can ever run.
            onSubmissionEmitted = { submission, origin -> drain.receiveEmittedSubmission(submission, origin) },
            onWindowClosed = { drain.drain() },
        )
        drain = WindowObservationSubmissionDrain(
            accumulator = accumulator,
            submissionRecordStore = submissionRecordStore,
            client = submissionClient,
            nowEpochMilliseconds = { (nowEpochSeconds() * 1_000.0).toLong() },
            configurationResolver = eventJoinRegistry?.let { registry ->
                WindowObservationSubmissionDrain.SubmissionConfigurationResolver { eventIdHex, completion ->
                    registry.resolveEventDefinition(eventIdHex, nowEpochSeconds().toLong()) { resolution, _ ->
                        completion(
                            resolution?.context?.let {
                                org.levarac.parallax.submission.createSubmissionOperatorConfigurationFromEventDefinition(it)
                            },
                        )
                    }
                }
            },
        )
        return WindowObservationRuntime(
            accumulator = accumulator,
            submissionDrain = drain,
            contextState = contextState,
        ).also { runtime ->
            activeFilesPath = filesPath
            activeRuntime = runtime
        }
    }
}

/** Native ENIN-window/effect adapter; canonical Observation decisions stay in shared. */
internal class WindowObservationAccumulator(
    private val context: () -> WindowObservationContext?,
    private val cryptography: SensingCryptography,
    private val ledgerStore: UnsentWindowLedgerStore,
    private val draftStore: WindowObservationDraftStore,
    private val observationDirectory: File,
    private val nowEpochSeconds: () -> Double,
    /**
     * Defaults to a sibling of [observationDirectory] so that every existing
     * test — one temp directory per test, ledger/draft/observations all
     * colocated inside it — gets an isolated submission-record store for
     * free. A test that cares about submission records passes its own.
     */
    private val submissionRecordStore: SubmissionRecordStore =
        SubmissionRecordStore(requireNotNull(observationDirectory.parentFile).resolve("submission-records-v1.json")),
    private val newWindowId: () -> UUID = UUID::randomUUID,
    ledgerInstanceId: () -> String = { UUID.randomUUID().toHex() },
    /**
     * Sink for a submission that surfaces from a ledger write this class
     * made for an unrelated reason — see [SubmissionEmissionOrigin]'s doc.
     * [WindowObservationSubmissionDrain] wires this to itself; tests that do
     * not exercise the drain may leave it at the no-op default.
     */
    private val onSubmissionEmitted: (UnsentWindowSubmission, SubmissionEmissionOrigin) -> Unit = { _, _ -> },
    /** beid#525's "after a window's durable close" drain trigger — see [closeCurrentWindow]. */
    private val onWindowClosed: () -> Unit = {},
) {
    private var ledger: UnsentWindowLedger = ledgerStore.load()?.ledger
        ?: requireNotNull(createUnsentWindowLedger(ledgerInstanceId()).ledger)
    private var enin: Long? = null
    private var rpids = linkedSetOf<String>()
    private var reporterRpid: String? = null
    private var openedWindowId: UUID? = null
    private var openedContext: WindowObservationContext? = null
    private var openedReporterRpid: String? = null
    private var activeEventCode: String? = null
    private var recordingObserved = false
    private var recovered = false

    /**
     * Reads storage left by a previous process and reconciles it. **Call this
     * off the main thread, and never from a constructor.**
     *
     * It used to run from this class's `init`, which reached the filesystem
     * and — once beid#372 added evidence recovery — the event signing key,
     * during `EventJoinCoordinator` construction during Activity setup.
     * Constructor-time I/O was already there and its failures are transient
     * or data-shaped, so a relaunch clears them. A hardware-backed signing
     * key is different in kind: it can refuse with a user-not-authenticated
     * or permanently-invalidated condition that PERSISTS across launches,
     * cannot be prompted for because no UI exists yet, and is triggered by a
     * durable draft that is still on disk every single time. That is not a
     * crash the next launch clears; it is a boot loop escapable only by
     * wiping app data.
     *
     * Making the recovery an explicit call the caller schedules is what
     * removes that surface, rather than catching harder inside it. The catch
     * inside [restoreDurableDraftEvidence] stays, because a draft that cannot
     * be signed must still be set aside rather than retried forever.
     *
     * Safe to call more than once; the work happens on the first call only.
     */
    @Synchronized
    fun recoverAfterRelaunch() {
        if (recovered) return
        recovered = true
        // Order matters. The draft is promoted to a durable `.cose` FIRST so
        // that the reconcile pass below sees it as an ordinary durable
        // artifact. Reversing these two discards the still-open ledger row
        // before its evidence exists, which is precisely the loss beid#372 is
        // about.
        restoreDurableDraftEvidence()
        reconcileDurableArtifactsAfterRelaunch()
    }

    @Synchronized
    fun beginEvent(eventCode: String): Boolean {
        val previousEventCode = activeEventCode ?: openedContext?.eventCode ?: context()?.eventCode
        if (previousEventCode != null && previousEventCode != eventCode && !close()) return false
        activeEventCode = eventCode
        return true
    }

    /**
     * ⚠️ `@Synchronized` does NOT cover this function's default argument.
     * `eventCode` defaults to `context()?.eventCode`, and a Kotlin default
     * argument is evaluated at the CALL SITE, before the monitor is acquired.
     *
     * Harmless today: that state is written only by `updateContext` on the
     * main thread, and relaunch recovery never calls `observe` — it builds its
     * own context from the draft. It stops being theoretical the moment
     * anything calls `observe` off the main thread, and the recovery this
     * class now schedules is the first genuine second thread it has ever had.
     * Noted rather than changed, because changing it means moving the default
     * inside the body and that is a signature change nothing yet needs.
     */
    @Synchronized
    fun observe(enin: Long, rpid: String, reporterRpid: String?, recording: Boolean, eventCode: String? = context()?.eventCode) {
        if (eventCode != null && !beginEvent(eventCode)) return
        if (this.enin != null && this.enin != enin) {
            openCurrentWindowIfEligible()
            if (!closeCurrentWindow()) return
        }
        if (this.enin == null) this.enin = enin
        val alreadyOpen = openedWindowId != null
        val normalizedRpid = rpid.lowercase()
        val openedId = openedWindowId
        val acceptedRpid = if (openedId == null) {
            true
        } else {
            preparedObservation(
                id = openedId,
                observationContext = requireNotNull(openedContext),
                observationReporterRpid = requireNotNull(openedReporterRpid),
                observedRpids = rpids + normalizedRpid,
            ) != null
        }
        if (acceptedRpid) rpids += normalizedRpid
        if (this.reporterRpid == null) this.reporterRpid = reporterRpid?.lowercase()
        recordingObserved = recordingObserved || recording
        openCurrentWindowIfEligible()
        // A window that opened during this call already wrote its draft
        // inside `openCurrentWindowIfEligible`; this is the incremental write
        // for every later detection, without which the observation set would
        // only ever reach storage when the window closes.
        if (alreadyOpen && openedWindowId != null) persistDraft()
    }

    /** Closes only an actual ENIN/session boundary. Lifecycle cleanup must not call this. */
    @Synchronized
    fun close(): Boolean {
        openCurrentWindowIfEligible()
        return closeCurrentWindow()
    }

    private fun openCurrentWindowIfEligible(): Boolean {
        if (openedWindowId != null) return true
        if (!recordingObserved) return false
        val openingContext = context() ?: return false
        if (activeEventCode != null && openingContext.eventCode != activeEventCode) return false
        val openingReporter = reporterRpid ?: return false
        val id = newWindowId()
        if (preparedObservation(id, openingContext, openingReporter, rpids) == null) return false
        apply(openUnsentWindow(ledger, id.toString().lowercase()))
        openedWindowId = id
        openedContext = openingContext
        openedReporterRpid = openingReporter
        persistDraft()
        persistSubmissionRecord(id.toString().lowercase(), openingContext.eventIdHex, openingContext.submissionConfiguration)
        return true
    }

    /**
     * Durably records what this window's artifact may submit under, before
     * the window can ever close — beid#525.
     *
     * At open, not at close: a window recovered through
     * [restoreDurableDraftEvidence] after a crash never reaches
     * [closeCurrentWindow] in the process that eventually promotes it, so a
     * close-time write would leave a config-less record for every
     * crash-recovered artifact. The draft itself does not carry
     * [WindowObservationContext.submissionConfiguration] (adding it there
     * would be a shared schema change this issue does not make), so this
     * store is the only durable copy — written once, while the context that
     * produced it is still the live one.
     */
    private fun persistSubmissionRecord(windowId: String, eventIdHex: String, configuration: SubmissionOperatorConfiguration?) {
        submissionRecordStore.add(
            if (configuration != null) {
                SubmissionRecord(
                    windowId = windowId,
                    eventIdHex = eventIdHex,
                    submissionEndpoint = configuration.submissionEndpoint,
                    receiptPublicKeyHex = configuration.receiptPublicKey.toByteArray().toHex(),
                    operatorIdHex = configuration.operatorId.toByteArray().toHex(),
                    eventDefinitionDigestHex = configuration.eventDefinitionDigest?.toByteArray()?.toHex(),
                    validFrom = configuration.validFrom,
                    validUntil = configuration.validUntil,
                    unresolvedReason = null,
                )
            } else {
                SubmissionRecord(
                    windowId = windowId,
                    eventIdHex = eventIdHex,
                    submissionEndpoint = null,
                    receiptPublicKeyHex = null,
                    operatorIdHex = null,
                    eventDefinitionDigestHex = null,
                    validFrom = null,
                    validUntil = null,
                    // beid#525: the drain resolves this later by eventIdHex
                    // via a fresh registry lookup (the nearby-card-tap join
                    // path never had a verified Event Definition to derive
                    // from at open time) — see
                    // WindowObservationSubmissionDrain.SubmissionConfigurationResolver.
                    unresolvedReason = "no verified Event Definition was available when this window opened",
                )
            },
        )
    }

    private fun closeCurrentWindow(): Boolean {
        val id = openedWindowId
        val closingEnin = enin
        if (id == null || closingEnin == null) {
            clearCurrentWindow()
            return true
        }
        val closingContext = openedContext ?: return false
        val closingReporter = openedReporterRpid ?: return false
        val prepared = preparedObservation(id, closingContext, closingReporter, rpids) ?: return false
        val signature = cryptography.signWindowReport(
            closingContext.eventCode,
            prepared.signatureStructure.toByteArray(),
        )
        val signed = prepared.signWithCompactSignatureHex(signature.r.toHex(), signature.s.toHex())
        val stored = storeSignedObservation(signed)
        val digest = stored.observationDigest.toByteArray().toHex()
        persistObservation(id.toString().lowercase(), digest, stored.signedBytes.toByteArray())
        // The draft is dropped by `clearCurrentWindow` below, AFTER the ledger
        // write — deliberately not before it. Clearing earlier would shrink
        // the window in which the artifact and the draft both exist, but
        // `clear` can itself throw, and this gap, between the artifact
        // becoming durable and the ledger recording it, is precisely the one
        // whose interruption is expensive. Adding a throw site to it buys
        // nothing, because `restoreDurableDraftEvidence` already discards a
        // draft whose window has a durable artifact rather than signing it
        // again.
        apply(closeUnsentWindow(ledger, id.toString().lowercase(), digest))
        clearCurrentWindow()
        // beid#525's "after a window's durable close" drain trigger. Safe to
        // call while still holding this instance's monitor: `@Synchronized`
        // is reentrant for the calling thread, and the drain's own
        // `beginNextSubmissionAttempt` call is itself `@Synchronized` on
        // this same accumulator. Only the synchronous, already-local
        // ledger-touching part runs on this thread; `SubmissionClient`
        // dispatches the actual HTTP call onto its own coroutine scope.
        onWindowClosed()
        return true
    }

    private fun preparedObservation(
        id: UUID,
        observationContext: WindowObservationContext,
        observationReporterRpid: String,
        observedRpids: Collection<String>,
        observationEnin: Long? = enin,
    ): PreparedObservationV1? {
        val closingEnin = observationEnin ?: return null
        val evidence = createMutualSensingWindowEvidence(
            idHex = id.toHex(),
            eventIdHex = observationContext.eventIdHex,
            eventDefinitionDigestHex = observationContext.eventDefinitionDigestHex,
            observerHex = cryptography.eventSigningPublicKey(observationContext.eventCode).toHex(),
            finalizedAt = nowEpochSeconds(),
            reporterRpidHex = observationReporterRpid,
            enin = closingEnin,
            observedRpidHexes = observedRpids.toList(),
            participantCommitmentHex = observationContext.participantCommitmentHex,
        ) ?: return null
        return (prepareMutualSensingObservation(evidence) as? ObservationPreparationResult.Eligible)?.prepared
    }

    private fun clearCurrentWindow() {
        draftStore.clear()
        enin = null
        rpids.clear()
        reporterRpid = null
        openedWindowId = null
        openedContext = null
        openedReporterRpid = null
        recordingObserved = false
    }

    /**
     * ⚠️ `confirmUnsentWindowLedgerPersistence` always re-checks for a durable
     * submission ready to emit, regardless of why it was called — every
     * caller here is a writer-side concern (open/close/relaunch-reconcile),
     * none of which "mean" to touch submission state, but the shared
     * reducer's `emitDurableSubmissionIfNeeded` runs anyway and — the
     * earlier form of this method — silently discarded it if it fired.
     * Beid#525's crash-safety property depends on that emission never being
     * lost, so it is routed to [onSubmissionEmitted] as [SubmissionEmissionOrigin.UNCONFIRMED]:
     * this method cannot prove the emission is a fresh, never-POSTed attempt
     * the way [beginNextSubmissionAttempt] can prove its own is.
     */
    private fun apply(transition: org.levarac.beid.shared.report.UnsentWindowLedgerTransition) {
        check(transition.isSuccess) { "Shared ledger rejected transition: ${transition.errorCode}" }
        if (!transition.changed) {
            ledger = transition.ledger
            return
        }
        val revision = ledgerStore.persist(transition)
        val confirmed = confirmUnsentWindowLedgerPersistence(transition.ledger, revision)
        ledger = confirmed.ledger
        confirmed.submission?.let { onSubmissionEmitted(it, SubmissionEmissionOrigin.UNCONFIRMED) }
    }

    /**
     * Begins the next submission attempt this ledger is willing to make right
     * now, or `null` if there is nothing to do — beid#525 part 1.
     *
     * Kept deliberately separate from [apply]: the brief's flow is
     * `prepareNextUnsentWindowSubmission` → persist → confirm → **consume the
     * returned `transition.submission`**, adopting the ledger even when
     * `changed == false`. Routing this through [apply] would re-lose exactly
     * the instruction [apply]'s own doc describes losing.
     *
     * The returned submission is safe to POST directly with no prior
     * `lookupReceipt`: it was durably confirmed IN_FLIGHT inside this exact
     * `@Synchronized` call, on this live process, so nothing has had a chance
     * to POST it yet — see [SubmissionEmissionOrigin.FRESH].
     */
    @Synchronized
    internal fun beginNextSubmissionAttempt(nowEpochMilliseconds: Long): UnsentWindowSubmission? {
        val prepared = prepareNextUnsentWindowSubmission(ledger, maximumWindowCount = 1, nowEpochMilliseconds)
        check(prepared.isSuccess) { "Shared ledger rejected submission preparation: ${prepared.errorCode}" }
        if (!prepared.changed) {
            // `changed == false` here is never itself a submission-bearing
            // transition (only `confirmUnsentWindowLedgerPersistence` and
            // `resumeUnsentWindowSubmissionAfterRestore` ever set `.submission`)
            // — adopting the ledger is the whole job.
            ledger = prepared.ledger
            return null
        }
        val revision = ledgerStore.persist(prepared)
        val confirmed = confirmUnsentWindowLedgerPersistence(prepared.ledger, revision)
        ledger = confirmed.ledger
        return confirmed.submission
    }

    /**
     * Re-announces a durable submission this ledger already knew about
     * before this process started, if any — beid#525's "after startup
     * reconciliation completes" trigger.
     *
     * The returned submission is never safe to POST directly: it existed
     * before this process did, so a now-dead process may already have
     * POSTed it. Callers must `lookupReceipt` first — see
     * [SubmissionEmissionOrigin.UNCONFIRMED].
     */
    @Synchronized
    internal fun resumeSubmissionAfterRestore(): UnsentWindowSubmission? {
        val resumed = resumeUnsentWindowSubmissionAfterRestore(ledger)
        check(resumed.isSuccess) { "Shared ledger rejected submission resume: ${resumed.errorCode}" }
        ledger = resumed.ledger
        return resumed.submission
    }

    /**
     * Records a verified acceptance for [submissionKey], keyed by
     * [acceptanceReceiptReference] — the caller must have already persisted
     * the receipt's exact bytes under that same reference before calling
     * this, per beid#525's crash-safety ordering (receipt bytes durable
     * first, then the ledger is told about the acceptance).
     */
    @Synchronized
    internal fun completeSubmissionAcceptance(submissionKey: String, acceptanceReceiptReference: String) {
        apply(recordUnsentWindowSubmissionAcceptance(ledger, submissionKey, acceptanceReceiptReference))
    }

    /**
     * Schedules (or, with [retryNotBeforeEpochMilliseconds] pinned to
     * [Long.MAX_VALUE], permanently defers) the next attempt for
     * [submissionKey].
     *
     * The shared reducer has no separate terminal state — only IN_FLIGHT,
     * RETRYABLE_FAILED and ACKNOWLEDGED — so beid#525's "stop automatic
     * POSTing for a terminal failure, or an artifact whose configuration
     * cannot be resolved" is implemented as RETRYABLE_FAILED with a retry
     * deadline that will not arrive. This is a deliberate overload of an
     * existing state, not a bug: the reducer's own head-of-line blocking
     * (`UnsentWindowLedger.kt:304-312`) then does the "stop and surface the
     * reason" job on its own, and nothing here schedules a timer for it.
     */
    @Synchronized
    internal fun completeSubmissionRetryable(submissionKey: String, retryNotBeforeEpochMilliseconds: Long) {
        apply(markUnsentWindowSubmissionRetryable(ledger, submissionKey, retryNotBeforeEpochMilliseconds))
    }

    /** Loads the exact durable bytes an already-selected submission must send — never re-signed, never re-derived. */
    internal fun loadStoredObservationBytes(windowId: String, expectedDigestHex: String): ByteArray? {
        val file = observationDirectory.resolve("$windowId--$expectedDigestHex.cose")
        if (!file.exists()) return null
        return file.readBytes()
    }

    private fun persistObservation(windowIdHex: String, digest: String, bytes: ByteArray) {
        if (!observationDirectory.exists()) check(observationDirectory.mkdirs())
        val destination = observationDirectory.resolve("$windowIdHex--$digest.cose")
        if (destination.exists()) {
            check(destination.readBytes().contentEquals(bytes))
            return
        }
        val temporary = File.createTempFile("observation-", ".tmp", observationDirectory)
        try {
            temporary.writeBytes(bytes)
            Files.move(temporary.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE)
        } finally {
            // A temp left behind by a failed write is never collected by
            // anything, and this method now has one more caller than it did.
            // Harmless in itself — relaunch reconciliation filters on the
            // `.cose` extension, so a stray `.tmp` cannot brick startup — but
            // the draft store already cleans up after itself and there is no
            // reason this should not.
            if (temporary.exists()) temporary.delete()
        }
    }

    /**
     * Writes the open window's observation set and context durably, replacing
     * whatever was there before.
     *
     * Called once when the window opens and again after every accepted
     * detection, so what is on disk is never older than the last observation
     * this process accepted. Shared rejecting any of it is a programming
     * error, not a runtime condition: the same values have already satisfied
     * `preparedObservation`, which is strictly stricter.
     */
    private fun persistDraft() {
        val id = openedWindowId ?: return
        val draftContext = openedContext ?: return
        val draftReporter = openedReporterRpid ?: return
        val draftEnin = enin ?: return
        val created = createWindowObservationDraft(
            windowId = id.toString().lowercase(),
            enin = draftEnin,
            eventCode = draftContext.eventCode,
            eventIdHex = draftContext.eventIdHex,
            eventDefinitionDigestHex = draftContext.eventDefinitionDigestHex,
            participantCommitmentHex = draftContext.participantCommitmentHex,
            reporterRpidHex = draftReporter,
        )
        var draft = checkNotNull(created.draft) {
            "Shared rejected an open window's draft: ${created.errorCode}"
        }
        rpids.forEach { observedRpid ->
            val appended = addWindowObservationDraftRpid(draft, observedRpid)
            draft = checkNotNull(appended.draft) {
                "Shared rejected an observed RPID for the draft: ${appended.errorCode}"
            }
        }
        draftStore.persist(draft)
    }

    /**
     * Promotes a durable draft left by a previous process into a signed
     * `.cose`, then drops it.
     *
     * Everything used here comes from storage. Nothing is read from the
     * ledger, and no ledger transition is applied: this produces an artifact
     * and stops. Closing the corresponding row is [reconcileDurableArtifactsAfterRelaunch]'s
     * job, and it reaches the same answer whether or not a matching row still
     * exists. Keeping the two one-directional is what makes "the session was
     * restored" and "the evidence was restored" impossible to substitute for
     * one another.
     *
     * `finalizedAt` is the one input that is deliberately not restored — it
     * is when the report was finalized, and finalizing after a relaunch
     * genuinely happens later. Every input that describes *what was observed*
     * is restored exactly.
     *
     * A draft that decodes but cannot produce a signed observation — because
     * it is ineligible, or because the event signing key is no longer
     * available — is quarantined rather than deleted or retried: it is
     * evidence that something was lost, and the next window must not inherit
     * it. Quarantining is also what keeps a stale draft from being able to
     * stop the app from starting at all; see the comment at the catch.
     */
    private fun restoreDurableDraftEvidence() {
        val draft = draftStore.load() ?: return
        // Runs before either exit below, not duplicated at each one: a
        // durable draft with no `SubmissionRecord` at all (not merely an
        // unresolved one) is possible at more than one point in this
        // function — the crash between `persistDraft()` and
        // `persistSubmissionRecord()` in `openCurrentWindowIfEligible` is
        // one; a second crash, after this function's own `persistObservation`
        // call below made the artifact durable but before it recorded that,
        // reaches `hasDurableArtifactFor(...)` true on the NEXT relaunch and
        // returns right here without ever touching `submissionRecordStore`.
        // Two copies of the same guard is how the second instance escaped
        // the first fix; hoisting it here instead covers every exit this
        // function has, including the quarantine path below, where it costs
        // nothing (an artifact that is never produced never becomes
        // eligible for a submission, so an unresolved record for it is
        // simply unused, not wrong). Without this, the drain would find no
        // record, be unable to recover `eventIdHex` from
        // `UnsentWindowSubmission` (which carries none), and `hold()` would
        // call `recordTerminalFailure` on a windowId
        // `JsonRecordFileStore.updateRecord` cannot find — a silent no-op —
        // permanently and invisibly stalling every window behind this one on
        // the device. `draft.eventIdHex` is the same field already used to
        // build `restoredContext` below; no new field, no new store method.
        // The registry-lookup fallback then resolves it exactly as it does
        // for the nearby-join path. Guarded on absence, not unconditional: a
        // crash after the original open-time write already succeeded must
        // not overwrite an already-resolved record with an unresolved one.
        if (submissionRecordStore.recordFor(draft.windowId) == null) {
            persistSubmissionRecord(draft.windowId, draft.eventIdHex, configuration = null)
        }
        if (hasDurableArtifactFor(draft.windowId)) {
            // The previous process died after writing the artifact and before
            // dropping the draft. Signing again would produce a second
            // artifact for one window — a different `finalizedAt` means a
            // different digest, so it would not even collide — and relaunch
            // reconciliation fails closed on exactly that conflict.
            draftStore.clear()
            return
        }
        val restoredContext = WindowObservationContext(
            eventCode = draft.eventCode,
            eventIdHex = draft.eventIdHex,
            eventDefinitionDigestHex = draft.eventDefinitionDigestHex,
            participantCommitmentHex = draft.participantCommitmentHex,
        )
        val id = try {
            UUID.fromString(draft.windowId)
        } catch (_: IllegalArgumentException) {
            null
        }
        val observedRpids = List(draft.observedRpidCount) { index ->
            requireNotNull(draft.observedRpidAt(index))
        }
        // Both the preparation and the signing reach the event signing key,
        // and this runs inside a constructor — so a key that is gone would
        // otherwise take the whole app down at launch rather than costing one
        // window. A draft outlives its process by design; the key need not,
        // since the user may have left the event, or the Keystore entry may
        // have been invalidated by a lock-screen change. Barnard ships as a
        // binary dependency with no sources here, so what it does for an
        // absent key cannot be read — which is exactly why this is caught
        // unconditionally rather than for the one exception type that seemed
        // likely.
        //
        // The disk writes below are deliberately OUTSIDE this: a failed write
        // is transient, and quarantining a draft for it would destroy
        // recoverable evidence over a full disk. Leaving the draft in place
        // lets the next launch try again.
        val signed = try {
            val prepared = id?.let {
                preparedObservation(
                    id = it,
                    observationContext = restoredContext,
                    observationReporterRpid = draft.reporterRpidHex,
                    observedRpids = observedRpids,
                    observationEnin = draft.enin,
                )
            }
            prepared?.let {
                val signature = cryptography.signWindowReport(
                    restoredContext.eventCode,
                    it.signatureStructure.toByteArray(),
                )
                it.signWithCompactSignatureHex(signature.r.toHex(), signature.s.toHex())
            }
        } catch (_: Exception) {
            null
        }
        if (signed == null) {
            draftStore.quarantineUnusable()
            return
        }
        val stored = storeSignedObservation(signed)
        persistObservation(
            draft.windowId,
            stored.observationDigest.toByteArray().toHex(),
            stored.signedBytes.toByteArray(),
        )
        draftStore.clear()
    }

    private fun hasDurableArtifactFor(windowId: String): Boolean =
        observationDirectory.listFiles().orEmpty().any { artifact ->
            artifact.isFile && artifact.name.startsWith("$windowId--") && artifact.extension == "cose"
        }

    private fun reconcileDurableArtifactsAfterRelaunch() {
        val recoveryInput = createUnsentWindowObservationRecoveryInput()
        observationDirectory.listFiles().orEmpty()
            .filter { it.isFile && it.extension == "cose" }
            .sortedBy { it.name }
            .forEach { artifact ->
                val match = ARTIFACT_FILE.matchEntire(artifact.name)
                    ?: error("Invalid durable observation artifact name: ${artifact.name}")
                val (windowId, expectedDigest) = match.destructured
                val restored = restoreStoredObservation(artifact.readBytes().toHex())
                    ?: error("Invalid durable observation artifact: ${artifact.name}")
                check(restored.observationDigest.toByteArray().toHex() == expectedDigest) {
                    "Durable observation digest mismatch: ${artifact.name}"
                }
                check(addPersistedUnsentWindowObservationForRecovery(recoveryInput, windowId, expectedDigest)) {
                    "Invalid durable observation recovery input: ${artifact.name}"
                }
            }
        apply(reconcileUnsentWindowLedgerAfterRelaunch(ledger, recoveryInput))
    }

    private companion object {
        val ARTIFACT_FILE = Regex("([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})--([0-9a-f]{64})\\.cose")
    }
}

private fun UUID.toHex(): String = "%016x%016x".format(mostSignificantBits, leastSignificantBits)

private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }

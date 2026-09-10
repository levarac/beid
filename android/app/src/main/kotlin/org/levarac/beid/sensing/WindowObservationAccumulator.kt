package org.levarac.beid.sensing

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import org.levarac.beid.persistence.UnsentWindowLedgerStore
import org.levarac.beid.persistence.WindowObservationDraftStore
import org.levarac.beid.shared.report.UnsentWindowLedger
import org.levarac.beid.shared.report.addPersistedUnsentWindowObservationForRecovery
import org.levarac.beid.shared.report.addWindowObservationDraftRpid
import org.levarac.beid.shared.report.closeUnsentWindow
import org.levarac.beid.shared.report.confirmUnsentWindowLedgerPersistence
import org.levarac.beid.shared.report.createUnsentWindowObservationRecoveryInput
import org.levarac.beid.shared.report.createUnsentWindowLedger
import org.levarac.beid.shared.report.createWindowObservationDraft
import org.levarac.beid.shared.report.openUnsentWindow
import org.levarac.beid.shared.report.reconcileUnsentWindowLedgerAfterRelaunch
import org.levarac.parallax.observation.ObservationPreparationResult
import org.levarac.parallax.observation.PreparedObservationV1
import org.levarac.parallax.observation.createMutualSensingWindowEvidence
import org.levarac.parallax.observation.prepareMutualSensingObservation
import org.levarac.parallax.submission.restoreStoredObservation
import org.levarac.parallax.submission.storeSignedObservation

internal data class WindowObservationContext(
    val eventCode: String,
    val eventIdHex: String,
    val eventDefinitionDigestHex: String,
    val participantCommitmentHex: String? = null,
)

internal class WindowObservationContextState {
    var value: WindowObservationContext? = null
}

internal class WindowObservationRuntime internal constructor(
    val accumulator: WindowObservationAccumulator,
    private val contextState: WindowObservationContextState,
) {
    fun updateContext(context: WindowObservationContext?) {
        contextState.value = context
    }

    fun beginEvent(eventCode: String): Boolean = accumulator.beginEvent(eventCode)
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
    ): WindowObservationRuntime {
        val filesPath = filesDir.toPath().toAbsolutePath().normalize().toString()
        activeRuntime?.let { runtime ->
            check(activeFilesPath == filesPath) { "Window observation runtime cannot change storage roots" }
            return runtime
        }
        val contextState = WindowObservationContextState()
        return WindowObservationRuntime(
            accumulator = WindowObservationAccumulator(
                context = { contextState.value },
                cryptography = cryptography,
                ledgerStore = UnsentWindowLedgerStore.recoveringCorruptSnapshot(
                    UnsentWindowLedgerStore.defaultFile(filesDir),
                ).store,
                draftStore = WindowObservationDraftStore(
                    WindowObservationDraftStore.defaultFile(filesDir),
                ),
                observationDirectory = File(filesDir, "canonical-observations-v1"),
                nowEpochSeconds = nowEpochSeconds,
                newWindowId = newWindowId,
                ledgerInstanceId = ledgerInstanceId,
                reconcileAfterRelaunch = true,
            ),
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
    private val newWindowId: () -> UUID = UUID::randomUUID,
    ledgerInstanceId: () -> String = { UUID.randomUUID().toHex() },
    reconcileAfterRelaunch: Boolean = false,
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

    init {
        if (reconcileAfterRelaunch) {
            // Order matters. The draft is promoted to a durable `.cose` FIRST
            // so that the reconcile pass below sees it as an ordinary durable
            // artifact. Reversing these two discards the still-open ledger row
            // before its evidence exists, which is precisely the loss beid#372
            // is about.
            restoreDurableDraftEvidence()
            reconcileDurableArtifactsAfterRelaunch()
        }
    }

    fun beginEvent(eventCode: String): Boolean {
        val previousEventCode = activeEventCode ?: openedContext?.eventCode ?: context()?.eventCode
        if (previousEventCode != null && previousEventCode != eventCode && !close()) return false
        activeEventCode = eventCode
        return true
    }

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
        return true
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
        // The evidence is durable as an artifact from here on, so the draft
        // has nothing left to protect. Dropping it before the ledger write
        // keeps the gap in which both exist as small as this can make it;
        // `restoreDurableDraftEvidence` closes the gap that remains.
        draftStore.clear()
        apply(closeUnsentWindow(ledger, id.toString().lowercase(), digest))
        clearCurrentWindow()
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

    private fun apply(transition: org.levarac.beid.shared.report.UnsentWindowLedgerTransition) {
        check(transition.isSuccess) { "Shared ledger rejected transition: ${transition.errorCode}" }
        if (!transition.changed) {
            ledger = transition.ledger
            return
        }
        val revision = ledgerStore.persist(transition)
        ledger = confirmUnsentWindowLedgerPersistence(transition.ledger, revision).ledger
    }

    private fun persistObservation(windowIdHex: String, digest: String, bytes: ByteArray) {
        if (!observationDirectory.exists()) check(observationDirectory.mkdirs())
        val destination = observationDirectory.resolve("$windowIdHex--$digest.cose")
        if (destination.exists()) {
            check(destination.readBytes().contentEquals(bytes))
            return
        }
        val temporary = File.createTempFile("observation-", ".tmp", observationDirectory)
        temporary.writeBytes(bytes)
        Files.move(temporary.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE)
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
     * A draft that decodes but cannot produce an eligible observation is
     * quarantined rather than deleted or retried: it is evidence that
     * something was lost, and the next window must not inherit it.
     */
    private fun restoreDurableDraftEvidence() {
        val draft = draftStore.load() ?: return
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
        val prepared = id?.let {
            preparedObservation(
                id = it,
                observationContext = restoredContext,
                observationReporterRpid = draft.reporterRpidHex,
                observedRpids = observedRpids,
                observationEnin = draft.enin,
            )
        }
        if (prepared == null) {
            draftStore.quarantineUnusable()
            return
        }
        val signature = cryptography.signWindowReport(
            restoredContext.eventCode,
            prepared.signatureStructure.toByteArray(),
        )
        val signed = prepared.signWithCompactSignatureHex(signature.r.toHex(), signature.s.toHex())
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

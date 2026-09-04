package org.levarac.beid.sensing

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import org.levarac.beid.persistence.UnsentWindowLedgerStore
import org.levarac.beid.shared.report.UnsentWindowLedger
import org.levarac.beid.shared.report.addPersistedUnsentWindowObservationForRecovery
import org.levarac.beid.shared.report.closeUnsentWindow
import org.levarac.beid.shared.report.confirmUnsentWindowLedgerPersistence
import org.levarac.beid.shared.report.createUnsentWindowObservationRecoveryInput
import org.levarac.beid.shared.report.createUnsentWindowLedger
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

    init {
        if (reconcileAfterRelaunch) reconcileDurableArtifactsAfterRelaunch()
    }

    fun observe(enin: Long, rpid: String, reporterRpid: String?, recording: Boolean) {
        if (this.enin != null && this.enin != enin && !closeCurrentWindow()) return
        if (this.enin == null) this.enin = enin
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
        if (recording && openedWindowId == null) {
            val id = newWindowId()
            val openingContext = context() ?: return
            val openingReporter = this.reporterRpid ?: return
            if (preparedObservation(id, openingContext, openingReporter, rpids) == null) return
            apply(openUnsentWindow(ledger, id.toString().lowercase()))
            openedWindowId = id
            openedContext = openingContext
            openedReporterRpid = openingReporter
        }
    }

    /** Closes only an actual ENIN/session boundary. Lifecycle cleanup must not call this. */
    fun close(): Boolean = closeCurrentWindow()

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
        apply(closeUnsentWindow(ledger, id.toString().lowercase(), digest))
        clearCurrentWindow()
        return true
    }

    private fun preparedObservation(
        id: UUID,
        observationContext: WindowObservationContext,
        observationReporterRpid: String,
        observedRpids: Collection<String>,
    ): PreparedObservationV1? {
        val closingEnin = enin ?: return null
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
        enin = null
        rpids.clear()
        reporterRpid = null
        openedWindowId = null
        openedContext = null
        openedReporterRpid = null
    }

    private fun apply(transition: org.levarac.beid.shared.report.UnsentWindowLedgerTransition) {
        check(transition.isSuccess) { "Shared ledger rejected transition: ${transition.errorCode}" }
        ledger = transition.ledger
        if (!transition.changed) return
        val revision = ledgerStore.persist(transition)
        ledger = confirmUnsentWindowLedgerPersistence(ledger, revision).ledger
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

package org.levarac.beid.sensing

import java.io.File
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.persistence.SessionAggregateSnapshotStore
import org.levarac.beid.persistence.SessionCheckpointStore
import org.levarac.beid.persistence.SubmissionRecordStore
import org.levarac.beid.persistence.UnsentWindowLedgerStore
import org.levarac.beid.persistence.WindowObservationDraftStore

/** Process-owned storage objects. Coordinator disposal never invalidates another writer. */
internal class SessionCheckpointRuntimeOwner {
    private val records = mutableMapOf<String, ProofRecordStore>()
    private val bindings = mutableMapOf<String, BindingRecordStore>()
    private val proofs = mutableMapOf<String, SelfProofRecordStore>()
    private val aggregates = mutableMapOf<String, SessionAggregateSnapshotStore>()
    private val checkpoints = mutableMapOf<String, SessionCheckpointStore>()
    private val serializations = mutableMapOf<String, SessionCheckpointSerialization>()
    private val submissions = mutableMapOf<String, SubmissionRecordStore>()
    private val ledgers = mutableMapOf<String, UnsentWindowLedgerStore>()
    private val drafts = mutableMapOf<String, WindowObservationDraftStore>()

    @Synchronized
    fun proofRecordStore(file: File, initial: ProofRecordStore? = null): ProofRecordStore =
        records.getOrPut(file.canonicalPath) {
            (initial ?: ProofRecordStore(file)).also { it.serialization = serializationForFile(file) }
        }

    @Synchronized
    fun bindingStore(file: File, initial: BindingRecordStore? = null): BindingRecordStore =
        bindings.getOrPut(file.canonicalPath) {
            (initial ?: BindingRecordStore(file)).also { it.serialization = serializationForFile(file) }
        }

    @Synchronized
    fun submissionStore(file: File): SubmissionRecordStore =
        submissions.getOrPut(file.canonicalPath) {
            SubmissionRecordStore(file)
        }

    @Synchronized
    fun ledgerStore(file: File): UnsentWindowLedgerStore =
        ledgers.getOrPut(file.canonicalPath) {
            UnsentWindowLedgerStore.recoveringCorruptSnapshot(file).store
        }

    @Synchronized
    fun draftStore(file: File): WindowObservationDraftStore =
        drafts.getOrPut(file.canonicalPath) {
            WindowObservationDraftStore(file)
        }

    fun serializationForFile(file: File): SessionCheckpointSerialization =
        serialization(SessionCheckpointStore.defaultDirectory(requireNotNull(file.canonicalFile.parentFile)))

    @Synchronized
    fun selfProofStore(file: File, initial: SelfProofRecordStore? = null): SelfProofRecordStore =
        proofs.getOrPut(file.canonicalPath) {
            (initial ?: SelfProofRecordStore(file)).also { it.serialization = serializationForFile(file) }
        }

    @Synchronized
    fun aggregateStore(file: File, initial: SessionAggregateSnapshotStore? = null): SessionAggregateSnapshotStore =
        aggregates.getOrPut(file.canonicalPath) {
            (initial ?: SessionAggregateSnapshotStore(file)).also { it.serialization = serializationForFile(file) }
        }

    @Synchronized
    fun checkpointStore(directory: File): SessionCheckpointStore =
        checkpoints.getOrPut(directory.canonicalPath) { SessionCheckpointStore(directory) }

    @Synchronized
    fun serialization(directory: File): SessionCheckpointSerialization =
        serializations.getOrPut(directory.canonicalPath) { SessionCheckpointSerialization() }
}

internal val ProcessSessionCheckpointRuntimeOwner = SessionCheckpointRuntimeOwner()

package org.levarac.beid.sensing

import java.io.File
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.persistence.SessionAggregateSnapshotStore
import org.levarac.beid.persistence.SessionCheckpointStore

/** Process-owned storage objects. Coordinator disposal never invalidates another writer. */
internal class SessionCheckpointRuntimeOwner {
    private val proofs = mutableMapOf<String, SelfProofRecordStore>()
    private val aggregates = mutableMapOf<String, SessionAggregateSnapshotStore>()
    private val checkpoints = mutableMapOf<String, SessionCheckpointStore>()
    private val serializations = mutableMapOf<String, SessionCheckpointSerialization>()

    @Synchronized
    fun selfProofStore(file: File, initial: SelfProofRecordStore? = null): SelfProofRecordStore =
        proofs.getOrPut(file.canonicalPath) { initial ?: SelfProofRecordStore(file) }

    @Synchronized
    fun aggregateStore(file: File, initial: SessionAggregateSnapshotStore? = null): SessionAggregateSnapshotStore =
        aggregates.getOrPut(file.canonicalPath) { initial ?: SessionAggregateSnapshotStore(file) }

    @Synchronized
    fun checkpointStore(directory: File): SessionCheckpointStore =
        checkpoints.getOrPut(directory.canonicalPath) { SessionCheckpointStore(directory) }

    @Synchronized
    fun serialization(directory: File): SessionCheckpointSerialization =
        serializations.getOrPut(directory.canonicalPath) { SessionCheckpointSerialization() }
}

internal val ProcessSessionCheckpointRuntimeOwner = SessionCheckpointRuntimeOwner()

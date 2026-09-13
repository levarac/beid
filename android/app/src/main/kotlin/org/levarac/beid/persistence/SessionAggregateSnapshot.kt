package org.levarac.beid.persistence

import java.io.File
import java.util.UUID
import org.levarac.beid.shared.aggregation.SessionAggregate
import org.levarac.beid.shared.aggregation.decodeSessionAggregateSnapshot
import org.levarac.beid.shared.aggregation.encodeSessionAggregateSnapshot
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

data class SessionAggregateSnapshotRecord(
    val proofId: UUID,
    val snapshotText: String,
)

/** Durable one-snapshot-per-proof store using the shared canonical codec. */
class SessionAggregateSnapshotStore(file: File) {
    private val store = JsonRecordFileStore(
        file = file,
        schemaVersion = SCHEMA_VERSION,
        toJson = ::toJson,
        fromJson = ::fromJson,
    )

    val records: List<SessionAggregateSnapshotRecord> get() = store.records
    val isPersistenceSuspended: Boolean get() = store.isPersistenceSuspended

    fun persist(proofId: UUID, aggregate: SessionAggregate) {
        check(!store.isPersistenceSuspended) { "persistence_suspended" }
        val encoded = encodeSessionAggregateSnapshot(aggregate)
        check(encoded.isSuccess && encoded.snapshotText != null) { "aggregate_not_successful" }
        val existing = store.recordMatching { it.proofId == proofId }
        if (existing != null) {
            check(existing.snapshotText == encoded.snapshotText) { "conflicting_snapshot" }
            return
        }
        store.addRecord(SessionAggregateSnapshotRecord(proofId, encoded.snapshotText!!))
    }

    fun snapshot(proofId: UUID): SessionAggregate? {
        val record = store.recordMatching { it.proofId == proofId } ?: return null
        return decodeSessionAggregateSnapshot(record.snapshotText).aggregate
    }

    companion object {
        const val SCHEMA_VERSION = 1
        fun defaultFile(filesDir: File): File = File(filesDir, "session-aggregate-snapshots-v1.json")
        private fun toJson(record: SessionAggregateSnapshotRecord): JsonObject = buildJsonObject {
            put("proofId", record.proofId.toString())
            put("snapshotText", record.snapshotText)
        }
        private fun fromJson(json: JsonObject) = SessionAggregateSnapshotRecord(
            proofId = UUID.fromString(json.getValue("proofId").jsonPrimitive.content),
            snapshotText = json.getValue("snapshotText").jsonPrimitive.content,
        )
    }
}

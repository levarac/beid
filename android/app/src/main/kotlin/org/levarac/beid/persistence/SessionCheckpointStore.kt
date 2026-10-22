package org.levarac.beid.persistence

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.UUID
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import org.levarac.beid.shared.aggregation.SessionAggregate
import org.levarac.beid.shared.aggregation.decodeSessionAggregateSnapshot
import org.levarac.beid.shared.aggregation.encodeSessionAggregateSnapshot

/** Native session metadata; aggregate decisions and snapshot validation remain shared. */
internal data class SessionCheckpoint(
    val proofId: UUID,
    val eventCode: String,
    val eninStart: Long,
    val eninEnd: Long,
    val aggregate: SessionAggregate,
)

/**
 * Main-thread storage adapter over the existing atomic record writer and shared
 * aggregate codec. One file per proof keeps an unrecoverable older session from
 * being overwritten when a new session starts. Window ledger/draft evidence is
 * independent and continues through its existing shared recovery path.
 */
internal class SessionCheckpointStore(private val directory: File) {
    fun proofIds(): List<UUID> {
        if (!directory.exists()) return emptyList()
        val files = directory.listFiles() ?: throw IOException("Unable to list session checkpoints")
        return files.filter { it.extension == "json" }.mapNotNull {
            runCatching { UUID.fromString(it.nameWithoutExtension) }.getOrNull()
        }.sortedBy(UUID::toString)
    }

    fun persist(checkpoint: SessionCheckpoint) {
        val store = open(checkpoint.proofId)
        check(store.records.size <= 1 && store.records.all { it.proofId == checkpoint.proofId })
        if (!store.updateRecord({ it.proofId == checkpoint.proofId }) { checkpoint }) {
            store.addRecord(checkpoint)
        }
    }

    fun load(proofId: UUID): SessionCheckpoint? {
        if (!file(proofId).exists()) return null
        return open(proofId).records.single().also { check(it.proofId == proofId) }
    }

    fun clear(proofId: UUID) {
        // Unknown/corrupt bytes must not be silently discarded on graceful end.
        load(proofId) ?: return
        Files.deleteIfExists(file(proofId).toPath())
    }

    private fun file(proofId: UUID) = File(directory, "$proofId.json")

    private fun open(proofId: UUID) = JsonRecordFileStore(
        file = file(proofId),
        schemaVersion = 1,
        toJson = ::toJson,
        fromJson = ::fromJson,
    ).also { check(!it.isPersistenceSuspended) { "session_checkpoint_persistence_suspended" } }

    companion object {
        fun defaultDirectory(filesDir: File) = File(filesDir, "session-checkpoints-v1")

        private fun toJson(checkpoint: SessionCheckpoint): JsonObject {
            val encoded = encodeSessionAggregateSnapshot(checkpoint.aggregate)
            check(encoded.isSuccess) { "invalid_session_aggregate" }
            return buildJsonObject {
                put("proofId", checkpoint.proofId.toString())
                put("eventCode", checkpoint.eventCode)
                put("eninStart", checkpoint.eninStart)
                put("eninEnd", checkpoint.eninEnd)
                put("aggregateSnapshot", requireNotNull(encoded.snapshotText))
            }
        }

        private fun fromJson(json: JsonObject): SessionCheckpoint {
            val start = json.getValue("eninStart").jsonPrimitive.long
            val end = json.getValue("eninEnd").jsonPrimitive.long
            require(start >= 0 && end >= start)
            val eventCode = json.getValue("eventCode").jsonPrimitive.content
            require(eventCode.isNotEmpty())
            val aggregate = decodeSessionAggregateSnapshot(json.getValue("aggregateSnapshot").jsonPrimitive.content)
            require(aggregate.isSuccess)
            return SessionCheckpoint(
                proofId = UUID.fromString(json.getValue("proofId").jsonPrimitive.content),
                eventCode = eventCode,
                eninStart = start,
                eninEnd = end,
                aggregate = requireNotNull(aggregate.aggregate),
            )
        }
    }
}

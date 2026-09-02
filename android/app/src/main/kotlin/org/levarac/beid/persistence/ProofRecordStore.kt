package org.levarac.beid.persistence

import java.io.File
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * On-device JSON store for collected [ProofRecord]s — same pattern as
 * [BindingRecordStore]/[SelfProofRecordStore], plus mutation
 * ([updatePeersVerified]/[updateSignatureState], built on
 * [JsonRecordFileStore.updateRecord]) and a reactive read surface
 * ([recordsFlow]) for [org.levarac.beid.ui.screens.RecordsScreen].
 *
 * [recordsFlow] is safe to keep in sync with [store]'s in-memory [records]
 * on every mutation because this exact instance is the *only* writer of its
 * backing file — unlike a second store instance opened over a file another
 * object already writes (which would never observe those other writes),
 * there is no cross-instance staleness possible here.
 *
 * That alone is not enough, though: each mutating method is really two
 * steps — the durable write into [store] (already synchronized inside
 * [JsonRecordFileStore] on *its own* lock) and then reading `store.records`
 * back into [_recordsFlow]. Without a lock spanning both steps, two threads
 * calling these methods concurrently can interleave so that the thread
 * whose durable write finished *first* is also the one whose flow
 * assignment runs *last* — the file (and `store.records`) end up correct,
 * but [recordsFlow] can end up stale, silently missing the other thread's
 * write. [lock] closes that gap by making "durable write" + "flow
 * assignment" one atomic unit per call, so the last critical section to
 * complete through *this instance* is guaranteed to be the last flow
 * assignment too. This is a second, outer lock scoped to this class's own
 * state — [JsonRecordFileStore]'s internal lock still protects the file
 * and must not be removed as "redundant" once #235's threading answer
 * lands; the two locks protect different invariants. Same class of bug as
 * commit `1c7db20` (an unsynchronized read racing a write across threads),
 * caught in review before it shipped rather than after.
 */
class ProofRecordStore(file: File) {
    private val store = JsonRecordFileStore(
        file = file,
        schemaVersion = SCHEMA_VERSION,
        toJson = ::toJson,
        fromJson = ::fromJson,
    )

    private val lock = Any()

    val records: List<ProofRecord> get() = store.records
    val isPersistenceSuspended: Boolean get() = store.isPersistenceSuspended

    private val _recordsFlow = MutableStateFlow(store.records)
    val recordsFlow: StateFlow<List<ProofRecord>> = _recordsFlow.asStateFlow()

    fun add(record: ProofRecord) {
        synchronized(lock) {
            store.addRecord(record)
            _recordsFlow.value = store.records
        }
    }

    /** Grows a recording proof's peer count in place, mirroring iOS's `ProofStore.updatePeersVerified(for:to:)`. */
    fun updatePeersVerified(id: UUID, peersVerified: Int) {
        synchronized(lock) {
            store.updateRecord(
                predicate = { it.id == id },
                transform = { it.copy(peersVerified = peersVerified) },
            )
            _recordsFlow.value = store.records
        }
    }

    /** Sets a proof's derived signature status once self-proof/binding evidence exists, mirroring iOS's `ProofStore.updateSignatureState(for:to:)`. */
    fun updateSignatureState(id: UUID, hasSelfProof: Boolean, hasBinding: Boolean) {
        synchronized(lock) {
            store.updateRecord(
                predicate = { it.id == id },
                transform = { it.copy(hasSelfProof = hasSelfProof, hasBinding = hasBinding) },
            )
            _recordsFlow.value = store.records
        }
    }

    fun recordForId(id: UUID): ProofRecord? = store.recordMatching { it.id == id }

    companion object {
        const val SCHEMA_VERSION = 1

        fun defaultFile(filesDir: File): File = File(filesDir, "proof-records-v1.json")

        private fun toJson(record: ProofRecord): JsonObject = buildJsonObject {
            put("id", record.id.toString())
            put("eventCode", record.eventCode)
            put("createdAt", record.createdAt.toString())
            put("peersVerified", record.peersVerified)
            put("hasSelfProof", record.hasSelfProof)
            put("hasBinding", record.hasBinding)
        }

        private fun fromJson(json: JsonObject): ProofRecord = ProofRecord(
            id = UUID.fromString(json.getValue("id").jsonPrimitive.content),
            eventCode = json.getValue("eventCode").jsonPrimitive.content,
            createdAt = Instant.parse(json.getValue("createdAt").jsonPrimitive.content),
            peersVerified = json.getValue("peersVerified").jsonPrimitive.int,
            hasSelfProof = json.getValue("hasSelfProof").jsonPrimitive.boolean,
            hasBinding = json.getValue("hasBinding").jsonPrimitive.boolean,
        )
    }
}

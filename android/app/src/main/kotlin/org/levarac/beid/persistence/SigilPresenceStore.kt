package org.levarac.beid.persistence

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import org.levarac.beid.shared.aggregation.AggregationObservationInput
import org.levarac.beid.shared.sigil.SigilInput
import org.levarac.beid.shared.sigil.SigilPresenceSession
import org.levarac.beid.shared.sigil.decodeSigilPresenceSnapshot
import org.levarac.beid.shared.sigil.encodeSigilPresenceSnapshot

/**
 * One finished record's Sigil presence, persisted as opaque shared-encoded
 * text (beid#722, the Android port of iOS #653's `SigilPresenceRecord`).
 * [presenceText] is `encodeSigilPresenceSnapshot`'s canonical output; this type
 * never decodes or interprets it. [proofId] is the uniqueness key.
 */
data class SigilPresenceRecord(
    val proofId: UUID,
    val presenceText: String,
    val createdAtEpochMillis: Long,
)

/**
 * Payload-free on purpose: the reason is logged, and a log line must never
 * carry a token or a display id (`docs/decisions/issue-653-design.md` §3).
 * The message is the reason's name and nothing else. Do not add fields.
 */
class SigilPresenceStoreException(val reason: Reason) : IllegalStateException(reason.name) {
    enum class Reason {
        /**
         * Shared refused to encode the session (too many peers, a missing or
         * duplicate token, no windows, a foreign input). Nothing is written,
         * so the record keeps its neutral ring.
         */
        UNENCODABLE,

        /** A different text is already stored for this record. */
        CONFLICTING_PRESENCE,
    }
}

/**
 * On-device store for per-record Sigil presence (beid#722; iOS
 * `SigilPresenceStore`, beid#653).
 *
 * **On the device only.** The owner authorized keeping per-window, per-peer
 * presence on this device and nowhere else (DECISIONS 2026-09-27). This store
 * is the only place it is written, and nothing reads it except the Sigil
 * drawing path: never a submission, a signature, a public artifact or a log
 * line. Production places the file under `Context.noBackupFilesDir`
 * ([forDevice]), which Android excludes from Auto Backup and from
 * device-to-device transfer, always, "even if you try to include them"
 * (developer.android.com/identity/data/autobackup). Every other store in this
 * app lives under `filesDir` and IS backed up (#704); that is deliberately
 * not copied here, and no backup rule is needed or added for this file.
 *
 * Shape. Mechanical persistence only: `shared` owns the format, this store owns
 * the location and the atomic write. One immutable row per `proofId`; a
 * byte-identical re-submission is a no-op and a differing one throws
 * [SigilPresenceStoreException.Reason.CONFLICTING_PRESENCE]. A file that does
 * not parse is moved aside by [CorruptSnapshotQuarantine] and the store starts
 * empty, because this is display data and must never wedge a session. Only a
 * read failure that is not corruption (an I/O error), or a quarantine that
 * could not move the file, suspends writes ([isPersistenceSuspended]); rows
 * are then kept in memory only, as on iOS.
 *
 * Absence is the only "no data" signal: no row, a row shared refuses to
 * decode, or a session that could not be encoded all make [sigilInput] return
 * `null`, and a `null` record keeps the neutral ring. Nothing is inferred from
 * counts.
 */
class SigilPresenceStore(val file: File) {
    private val lock = Any()

    @Volatile
    var records: List<SigilPresenceRecord> = emptyList()
        private set

    /** Where a corrupt file was moved on load, if one was. */
    @Volatile
    var quarantinedFile: File? = null
        private set

    @Volatile
    var isPersistenceSuspended: Boolean = false
        private set

    /**
     * What [sigilInput] decoded for a row, kept because the lookup runs during
     * composition. Safe because a row never changes once written. Only rows
     * that exist are cached, so a row written later is still found.
     */
    private sealed class DecodedInput {
        class Decoded(val input: SigilInput) : DecodedInput()
        data object Rejected : DecodedInput()
    }

    private val decodedInputs = HashMap<UUID, DecodedInput>()

    init {
        synchronized(lock) { load() }
    }

    /**
     * Encodes the finished session through shared and stores it for
     * [proofId]. Throws [SigilPresenceStoreException.Reason.UNENCODABLE],
     * writing nothing, when shared refuses.
     */
    fun persist(
        session: SigilPresenceSession,
        observations: AggregationObservationInput,
        proofId: UUID,
        createdAtEpochMillis: Long = System.currentTimeMillis(),
    ): SigilPresenceRecord {
        val encoded = encodeSigilPresenceSnapshot(session, observations)
        val presenceText = encoded.snapshotText
        if (!encoded.isSuccess || presenceText == null) {
            throw SigilPresenceStoreException(SigilPresenceStoreException.Reason.UNENCODABLE)
        }
        return add(SigilPresenceRecord(proofId, presenceText, createdAtEpochMillis))
    }

    /**
     * The record's Sigil input, or `null` when there is no usable row.
     *
     * Memoized per `proofId`: repeated calls return the SAME instance. A
     * caller must treat it as read-only and hand it only to `layoutSigil`;
     * passing it to `addSigilPresence`/`addSigilPeer` would change the Sigil
     * of every later reader of that record.
     */
    fun sigilInput(proofId: UUID): SigilInput? = synchronized(lock) {
        when (val cached = decodedInputs[proofId]) {
            is DecodedInput.Decoded -> return@synchronized cached.input
            DecodedInput.Rejected -> return@synchronized null
            null -> Unit
        }
        val record = records.firstOrNull { it.proofId == proofId } ?: return@synchronized null
        val loaded = decodeSigilPresenceSnapshot(record.presenceText)
        val input = loaded.input
        if (!loaded.isSuccess || input == null) {
            decodedInputs[proofId] = DecodedInput.Rejected
            null
        } else {
            decodedInputs[proofId] = DecodedInput.Decoded(input)
            input
        }
    }

    /**
     * Removes the row for [proofId], if any. Android has no record-delete or
     * reset-all feature yet; whichever path deletes a record must call this.
     */
    fun remove(proofId: UUID): Unit = synchronized(lock) {
        decodedInputs.remove(proofId)
        if (records.none { it.proofId == proofId }) return@synchronized
        val updated = records.filter { it.proofId != proofId }
        if (!isPersistenceSuspended) save(updated)
        records = updated
    }

    private fun add(record: SigilPresenceRecord): SigilPresenceRecord = synchronized(lock) {
        records.firstOrNull { it.proofId == record.proofId }?.let { existing ->
            if (existing.presenceText != record.presenceText) {
                throw SigilPresenceStoreException(SigilPresenceStoreException.Reason.CONFLICTING_PRESENCE)
            }
            return@synchronized existing
        }
        val updated = records + record
        // Publish memory only after the atomic durable write succeeds.
        if (!isPersistenceSuspended) save(updated)
        records = updated
        record
    }

    private fun load() {
        if (!file.exists()) return
        val text = try {
            file.readText(Charsets.UTF_8)
        } catch (_: IOException) {
            // Not corruption: never quarantine a file that could not be read.
            isPersistenceSuspended = true
            return
        }
        val decoded = try {
            decodeRecords(text)
        } catch (_: Exception) {
            null
        }
        if (decoded != null) {
            records = decoded
            return
        }
        try {
            quarantinedFile = CorruptSnapshotQuarantine.quarantine(file)
        } catch (_: Exception) {
            // The bytes stay where they are; writing would destroy them.
            isPersistenceSuspended = true
        }
    }

    private fun decodeRecords(text: String): List<SigilPresenceRecord>? {
        val root = Json.parseToJsonElement(text).jsonObject
        if (root["schemaVersion"]?.jsonPrimitive?.int != SCHEMA_VERSION) return null
        val rows = root.getValue("records").jsonArray.map { element ->
            val row = element.jsonObject
            SigilPresenceRecord(
                proofId = UUID.fromString(row.getValue("proofId").jsonPrimitive.content),
                presenceText = row.getValue("presenceText").jsonPrimitive.content,
                createdAtEpochMillis = row.getValue("createdAt").jsonPrimitive.long,
            )
        }
        return if (rows.map { it.proofId }.toSet().size == rows.size) rows else null
    }

    private fun save(updated: List<SigilPresenceRecord>) {
        val root = buildJsonObject {
            put("schemaVersion", SCHEMA_VERSION)
            putJsonArray("records") { updated.forEach { add(toJson(it)) } }
        }
        val parent = file.absoluteFile.parentFile
            ?: throw IOException("No parent directory for the Sigil presence file")
        if (!parent.exists() && !parent.mkdirs()) {
            throw IOException("Unable to create the Sigil presence directory")
        }
        val temporary = File.createTempFile("${file.name}.", ".tmp", parent)
        try {
            FileOutputStream(temporary).use { output ->
                output.write(root.toString().toByteArray(Charsets.UTF_8))
                output.fd.sync()
            }
            try {
                Files.move(
                    temporary.toPath(),
                    file.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (error: AtomicMoveNotSupportedException) {
                throw IOException("Sigil presence storage does not support atomic replacement", error)
            }
        } finally {
            if (temporary.exists()) temporary.delete()
        }
    }

    companion object {
        const val SCHEMA_VERSION = 1

        private val deviceStores = HashMap<String, SigilPresenceStore>()

        /**
         * The file inside [directory]. Production passes
         * `Context.noBackupFilesDir` only, through [forDevice]; a dedicated
         * subdirectory keeps this data and its quarantine siblings together.
         */
        fun defaultFile(directory: File): File =
            File(File(directory, "sigil-presence"), "sigil-presence-v1.json")

        /**
         * The production store, under `Context.noBackupFilesDir` (beid#722
         * item 5) and one instance per process, so two coordinators never
         * hold diverging copies of the same file.
         */
        fun forDevice(context: Context): SigilPresenceStore {
            val file = defaultFile(context.noBackupFilesDir)
            val key = file.absoluteFile.toPath().normalize().toString()
            return synchronized(deviceStores) { deviceStores.getOrPut(key) { SigilPresenceStore(file) } }
        }

        private fun toJson(record: SigilPresenceRecord): JsonObject = buildJsonObject {
            put("proofId", record.proofId.toString())
            put("presenceText", record.presenceText)
            put("createdAt", record.createdAtEpochMillis)
        }
    }
}

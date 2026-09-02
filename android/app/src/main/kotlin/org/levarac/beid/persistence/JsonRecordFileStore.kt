package org.levarac.beid.persistence

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray

/**
 * Native storage boundary for a flat list of records, one JSON file, no
 * server call — the shape [BindingRecordStore]/[SelfProofRecordStore] both
 * need, factored out to keep the atomic-write mechanics in one place.
 * Mirrors the *pattern* of iOS's `BindingRecordStore`/`SelfProofStore`
 * (`RecordSchemaEnvelope`'s `{"schemaVersion":N,"records":[...]}` envelope,
 * flat JSON, `.atomic` write) at reduced scope: a first Android pass does
 * not preserve a corrupt file under a quarantined sibling name the way
 * iOS's `CorruptStoreQuarantine` does — it only refuses to overwrite it in
 * place ([isPersistenceSuspended]), which is enough to prevent the
 * data-destruction bug class iOS's own comments describe (beid#135) without
 * this pass also porting the rename/prune bookkeeping. See handoff.
 *
 * Uses `kotlinx-serialization-json`'s `JsonObject`/`JsonElement` tree API
 * directly (no `@Serializable` data classes, no
 * `kotlin("plugin.serialization")` compiler plugin) — the same style
 * already established in this repo by `shared/`'s `EtherscanRestAdapter.kt`
 * and friends, extended to `:app`.
 */
internal class JsonRecordFileStore<T>(
    private val file: File,
    private val schemaVersion: Int,
    private val toJson: (T) -> JsonObject,
    private val fromJson: (JsonObject) -> T,
) {
    private val lock = Any()

    var records: List<T> = emptyList()
        private set

    /**
     * Set once an existing file failed to parse as this store's JSON shape.
     * [addRecord] becomes a no-op while this is `true` — saving would
     * overwrite bytes this instance never actually captured into
     * [records].
     */
    var isPersistenceSuspended: Boolean = false
        private set

    init {
        synchronized(lock) { load() }
    }

    fun addRecord(record: T) {
        synchronized(lock) {
            if (isPersistenceSuspended) return
            records = records + record
            save()
        }
    }

    fun recordMatching(predicate: (T) -> Boolean): T? = records.firstOrNull(predicate)

    /**
     * Replaces the first record matching [predicate] with [transform]'s
     * result and persists it. No-op (returns `false`) if no record matches,
     * or if [isPersistenceSuspended] — saving would overwrite bytes this
     * instance never actually captured.
     */
    fun updateRecord(predicate: (T) -> Boolean, transform: (T) -> T): Boolean {
        synchronized(lock) {
            if (isPersistenceSuspended) return false
            val index = records.indexOfFirst(predicate)
            if (index == -1) return false
            records = records.toMutableList().also { it[index] = transform(it[index]) }
            save()
            return true
        }
    }

    private fun load() {
        if (!file.exists()) return
        val root = try {
            Json.parseToJsonElement(file.readText(Charsets.UTF_8)).jsonObject
        } catch (_: Exception) {
            isPersistenceSuspended = true
            return
        }
        val version = root["schemaVersion"]?.jsonPrimitive?.int
        if (version != schemaVersion) {
            // An unrecognized (or missing) schemaVersion is neither
            // definitely corrupt nor definitely garbage — same reasoning as
            // iOS's `RecordSchemaEnvelope.UnsupportedSchemaVersion`: leave
            // the file in place and stop writing, rather than guess.
            isPersistenceSuspended = true
            return
        }
        val recordsJson = root["records"]?.jsonArray
        if (recordsJson == null) {
            isPersistenceSuspended = true
            return
        }
        records = try {
            recordsJson.map { fromJson(it.jsonObject) }
        } catch (_: Exception) {
            isPersistenceSuspended = true
            emptyList()
        }
    }

    private fun save() {
        val root = buildJsonObject {
            put("schemaVersion", schemaVersion)
            putJsonArray("records") { records.forEach { record -> add(toJson(record)) } }
        }
        val text = root.toString()

        val parent = file.absoluteFile.parentFile
            ?: throw IOException("No parent directory for ${file.path}")
        if (!parent.exists() && !parent.mkdirs()) {
            throw IOException("Unable to create directory ${parent.path}")
        }

        val temporary = File.createTempFile("${file.name}.", ".tmp", parent)
        try {
            FileOutputStream(temporary).use { output ->
                output.write(text.toByteArray(Charsets.UTF_8))
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
                throw IOException("Record store does not support atomic replacement", error)
            }
        } finally {
            if (temporary.exists()) {
                temporary.delete()
            }
        }
    }
}

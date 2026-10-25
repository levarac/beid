package org.levarac.beid.persistence

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import org.levarac.beid.sensing.logRuntimeDiagnostic

/** The existing submission/ledger window id and its session's Proof. No other metadata. */
internal data class ReportProofLink(val windowId: UUID, val proofId: UUID)

/** No ids or file contents are carried by these errors. */
internal class ReportProofLinkStoreException(val reason: Reason) : IOException(reason.name) {
    enum class Reason { UNREADABLE, CONFLICTING_LINK }
}

/**
 * Display-only, on-device links (beid#769), matching iOS's ReportProofLinkStore.
 * The window accumulator is the only writer, at window close. Neither this
 * store nor its Proof ids enter the submission context, ledger, signing or drain.
 * Existing records and recovered drafts stay unlinked; nothing infers links.
 *
 * There is no delete API. Any future change that deletes a Proof or a report
 * record must delete the matching link rows in the same change.
 *
 * The file and its staging directory are excluded by both Android backup rules.
 * An unreadable file latches this instance unavailable and is never overwritten.
 */
internal class ReportProofLinkStore(
    private val file: File,
    private val writeFile: (File, ByteArray) -> Unit = ::atomicWrite,
) {
    private val proofByWindow = linkedMapOf<UUID, UUID>()
    private var unreadable = false

    init {
        try {
            if (!Files.notExists(file.toPath())) {
                val root = Json.parseToJsonElement(file.readText(Charsets.UTF_8)).jsonObject
                require(root.getValue("schemaVersion").jsonPrimitive.int == 1)
                val loaded = linkedMapOf<UUID, UUID>()
                root.getValue("records").jsonArray.forEach { value ->
                    val row = value.jsonObject
                    val windowId = UUID.fromString(row.getValue("windowId").jsonPrimitive.content)
                    val proofId = UUID.fromString(row.getValue("proofId").jsonPrimitive.content)
                    require(loaded[windowId] == null || loaded[windowId] == proofId)
                    loaded[windowId] = proofId
                }
                proofByWindow.putAll(loaded)
            }
        } catch (_: Exception) {
            unreadable = true
            logRuntimeDiagnostic("Report-to-proof link file is unreadable; links are unavailable and the file is left untouched")
        }
    }

    /** An unavailable file throws; an empty result means no links were recorded. */
    @Synchronized
    fun links(): List<ReportProofLink> {
        requireReadable()
        return proofByWindow.map { (windowId, proofId) -> ReportProofLink(windowId, proofId) }
    }

    /** Null means unlinked, including every pre-change window. */
    @Synchronized
    fun proofIdFor(windowId: UUID): UUID? {
        requireReadable()
        return proofByWindow[windowId]
    }

    @Synchronized
    fun windowIdsFor(proofId: UUID): Set<UUID> {
        requireReadable()
        return proofByWindow.filterValues { it == proofId }.keys.toSet()
    }

    /** The same pair is a no-op; a different Proof for an existing window is refused. */
    @Synchronized
    fun add(windowId: UUID, proofId: UUID) {
        requireReadable()
        proofByWindow[windowId]?.let { existing ->
            if (existing != proofId) {
                throw ReportProofLinkStoreException(ReportProofLinkStoreException.Reason.CONFLICTING_LINK)
            }
            return
        }
        val updated = proofByWindow + (windowId to proofId)
        val encoded = buildJsonObject {
            put("schemaVersion", 1)
            putJsonArray("records") {
                updated.forEach { (window, proof) ->
                    add(buildJsonObject {
                        put("windowId", window.toString())
                        put("proofId", proof.toString())
                    })
                }
            }
        }.toString().toByteArray(Charsets.UTF_8)
        writeFile(file, encoded)
        // Publish memory only after the atomic durable write succeeds.
        proofByWindow[windowId] = proofId
    }

    private fun requireReadable() {
        if (unreadable) throw ReportProofLinkStoreException(ReportProofLinkStoreException.Reason.UNREADABLE)
    }

    companion object {
        fun defaultFile(filesDir: File): File = File(filesDir, "report-proof-links.json")

        /** Same staged-write, fsync, atomic-rename sequence as JsonRecordFileStore. */
        private fun atomicWrite(file: File, bytes: ByteArray) {
            val parent = file.absoluteFile.parentFile ?: throw IOException("Link directory is unavailable")
            if (!parent.isDirectory && !parent.mkdirs()) throw IOException("Link directory is unavailable")
            // Exclude in-progress bytes too: backup rules cannot name random sibling temp files.
            val staging = File(parent, "report-proof-links-staging")
            if (!staging.isDirectory && !staging.mkdirs()) throw IOException("Link staging directory is unavailable")
            val temporary = File.createTempFile("links-", ".tmp", staging)
            try {
                FileOutputStream(temporary).use { output ->
                    output.write(bytes)
                    output.fd.sync()
                }
                Files.move(
                    temporary.toPath(), file.toPath(),
                    StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING,
                )
            } finally {
                // Cleanup must not turn a successful rename into a reported write failure.
                try {
                    temporary.delete()
                    staging.delete()
                } catch (_: Exception) {
                    // Both paths remain excluded from backup even if cleanup fails.
                }
            }
        }
    }
}

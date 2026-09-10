package org.levarac.beid.persistence

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.ConcurrentHashMap
import org.levarac.beid.shared.report.WindowObservationDraft
import org.levarac.beid.shared.report.decodeWindowObservationDraftSnapshot
import org.levarac.beid.shared.report.encodeWindowObservationDraftSnapshot

/**
 * Native storage boundary for the evidence of the window that is open right
 * now. Decides only filesystem ordering and atomic replacement; what a draft
 * may contain and how it is spelled stays in `shared`.
 *
 * Deliberately a *different file* from the unsent-window ledger snapshot,
 * because it answers a different question and must be restorable on its own.
 * Neither store reads the other. That separation is the point of beid#372:
 * restoring session state must not be able to masquerade as restoring proof
 * data, and the cheapest way to guarantee that is to give them no shared
 * state to confuse.
 *
 * Unlike the ledger there is no revision and no older-write guard. A draft is
 * strictly the newest observation set for one open window; there is exactly
 * one writer, and a later write always supersedes an earlier one.
 */
internal class WindowObservationDraftStore(private val file: File) {
    private val persistenceLock = lockFor(canonicalPathKey(file))

    /** Atomically replaces the durable draft with [draft]'s canonical text. */
    fun persist(draft: WindowObservationDraft) {
        synchronized(persistenceLock) {
            val snapshotText = encodeWindowObservationDraftSnapshot(draft)
            val parent = requireNotNull(file.absoluteFile.parentFile)
            if (!parent.exists() && !parent.mkdirs()) {
                throw IOException("Unable to create observation draft directory")
            }
            val temporary = File.createTempFile("${file.name}.", ".tmp", parent)
            try {
                FileOutputStream(temporary).use { output ->
                    output.write(snapshotText.toByteArray(StandardCharsets.UTF_8))
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
                    throw IOException("Draft storage does not support atomic replacement", error)
                }
            } finally {
                if (temporary.exists()) {
                    temporary.delete()
                }
            }
        }
    }

    /**
     * Returns the durable draft, or `null` when there is none.
     *
     * Bytes the shared decoder rejects are quarantined and reported as `null`
     * — a draft that cannot be read is *absent* evidence. It must never
     * decode into an empty draft, which would claim the device observed
     * nothing in a window where it may have observed a room full of people.
     */
    fun load(): WindowObservationDraft? = synchronized(persistenceLock) {
        if (!file.exists()) {
            return@synchronized null
        }
        val decoded = decodeWindowObservationDraftSnapshot(
            file.readText(StandardCharsets.UTF_8),
        )
        if (!decoded.isSuccess) {
            CorruptSnapshotQuarantine.quarantine(file)
            return@synchronized null
        }
        decoded.draft
    }

    /**
     * Preserves a draft that decoded but cannot be turned back into an
     * eligible observation, and frees the canonical path.
     *
     * Kept distinct from [clear] on purpose. Clearing says "this evidence has
     * been promoted to a durable artifact and is no longer needed"; this says
     * "this evidence could not be used and I do not know why", which is a
     * diagnosis worth keeping the bytes for. Deleting it would erase the only
     * record that observations were lost.
     */
    fun quarantineUnusable() {
        synchronized(persistenceLock) {
            if (file.exists()) {
                CorruptSnapshotQuarantine.quarantine(file)
            }
        }
    }

    /** Removes the durable draft once its window no longer needs recovering. */
    fun clear() {
        synchronized(persistenceLock) {
            if (file.exists() && !file.delete() && file.exists()) {
                throw IOException("Unable to clear the observation draft")
            }
        }
    }

    companion object {
        private val locksByPath = ConcurrentHashMap<String, Any>()

        fun defaultFile(filesDir: File): File =
            File(filesDir, "window-observation-draft-v1.snapshot")

        private fun lockFor(path: String): Any = locksByPath.computeIfAbsent(path) { Any() }

        private fun canonicalPathKey(file: File): String =
            file.toPath().toAbsolutePath().normalize().toString()
    }
}

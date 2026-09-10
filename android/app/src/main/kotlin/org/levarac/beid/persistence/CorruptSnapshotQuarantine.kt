package org.levarac.beid.persistence

import java.io.File
import java.nio.file.Files
import java.util.UUID

/**
 * Startup policy shared by every store that keeps one canonical snapshot
 * file: bytes the shared decoder rejects are preserved under a timestamped
 * sibling name rather than deleted, and the canonical path is left free so
 * the app can keep running.
 *
 * Extracted when a second store needed it. Mirrors iOS's
 * `CorruptStoreQuarantine`, including the cap of 5 — quarantine files
 * accumulate one per corruption event with nothing that ever removes them, so
 * a device that corrupts repeatedly must still have bounded disk usage while
 * keeping the most recent occurrences for diagnosis.
 *
 * This helper is only ever reached from a decode failure. Any other I/O error
 * — a permission error, the path being a directory — must propagate unchanged
 * with nothing quarantined: mistaking a transient read failure for corrupt
 * content is exactly what this isolation exists to prevent.
 */
internal object CorruptSnapshotQuarantine {
    const val MAX_QUARANTINED_SNAPSHOT_COUNT = 5
    private const val QUARANTINE_INFIX = ".corrupt-"

    /** Moves [file] aside and prunes older quarantined siblings; returns the preserved file. */
    fun quarantine(file: File): File {
        val quarantined = moveAside(file)
        pruneOld(file)
        return quarantined
    }

    private fun moveAside(file: File): File {
        val parent = requireNotNull(file.absoluteFile.parentFile)
        val quarantined = File(
            parent,
            "${file.name}$QUARANTINE_INFIX${System.currentTimeMillis()}-${UUID.randomUUID()}",
        )
        Files.move(file.toPath(), quarantined.toPath())
        return quarantined
    }

    private fun pruneOld(file: File) {
        val parent = file.absoluteFile.parentFile ?: return
        val prefix = "${file.name}$QUARANTINE_INFIX"
        val quarantined = (parent.listFiles() ?: return)
            .mapNotNull { candidate ->
                timestampMilliseconds(candidate.name, prefix)?.let { timestamp ->
                    candidate to timestamp
                }
            }
            .sortedBy { (_, timestamp) -> timestamp }
        if (quarantined.size <= MAX_QUARANTINED_SNAPSHOT_COUNT) {
            return
        }
        quarantined
            .take(quarantined.size - MAX_QUARANTINED_SNAPSHOT_COUNT)
            .forEach { (candidate, _) -> candidate.delete() }
    }

    private fun timestampMilliseconds(name: String, prefix: String): Long? {
        if (!name.startsWith(prefix)) {
            return null
        }
        val afterPrefix = name.substring(prefix.length)
        val dashIndex = afterPrefix.indexOf('-')
        if (dashIndex < 0) {
            return null
        }
        return afterPrefix.substring(0, dashIndex).toLongOrNull()
    }
}

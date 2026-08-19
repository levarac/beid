package org.levarac.beid.persistence

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import org.levarac.beid.shared.report.UnsentWindowLedgerLoadResult
import org.levarac.beid.shared.report.UnsentWindowLedgerTransition
import org.levarac.beid.shared.report.decodeUnsentWindowLedgerSnapshot

/** Distinguishes a snapshot whose bytes fail the shared decoder from any other I/O failure. */
internal class InvalidUnsentWindowLedgerSnapshotException :
    IOException("Invalid existing unsent-window ledger snapshot")

/**
 * Result of [UnsentWindowLedgerStore.recoveringCorruptSnapshot]: the opened
 * store, plus the quarantined file if the existing snapshot failed to decode.
 */
internal data class UnsentWindowLedgerStoreRecovery(
    val store: UnsentWindowLedgerStore,
    val quarantinedFile: File?,
)

/**
 * Native storage boundary for the shared ledger's already-encoded snapshot.
 *
 * This class decides only filesystem ordering and atomic replacement. Ledger
 * transitions, snapshot syntax, and report eligibility remain in `shared`.
 * No production caller exists yet: beid#121 was reduced to proving byte parity
 * against shared's golden vectors and porting corrupt-snapshot isolation, since
 * Android has no ledger writer to wire this to. Wiring and listing move to the
 * slice that adds a writer.
 */
internal class UnsentWindowLedgerStore private constructor(
    private val file: File,
    validateOnConstruction: Boolean,
) {
    constructor(file: File) : this(file, validateOnConstruction = true)

    private val persistenceLock = lockFor(canonicalPathKey(file))

    init {
        if (validateOnConstruction) {
            synchronized(persistenceLock) {
                durableRevision()
            }
        }
    }

    /**
     * Persists the exact snapshot bound to [transition]. Older completions are
     * ignored so a delayed write cannot replace a newer durable revision.
     */
    fun persist(transition: UnsentWindowLedgerTransition): Long =
        synchronized(persistenceLock) {
            require(transition.isSuccess && transition.changed) {
                "A successful changed ledger transition is required"
            }
            val snapshotText = requireNotNull(transition.snapshotText) {
                "Changed ledger transition has no snapshot"
            }
            val decoded = decodeUnsentWindowLedgerSnapshot(snapshotText)
            require(decoded.isSuccess && decoded.persistenceRevision == transition.persistenceRevision) {
                "Transition revision does not match its canonical snapshot"
            }

            val incomingRevision = transition.persistenceRevision
            val durableRevision = durableRevision()
            if (incomingRevision < durableRevision) {
                return@synchronized durableRevision
            }
            if (incomingRevision == durableRevision) {
                val existing = if (file.exists()) {
                    file.readText(StandardCharsets.UTF_8)
                } else {
                    null
                }
                if (existing != snapshotText) {
                    throw IOException("Conflicting snapshot for persisted revision $incomingRevision")
                }
                return@synchronized durableRevision
            }

            val parent = requireNotNull(file.absoluteFile.parentFile)
            if (!parent.exists() && !parent.mkdirs()) {
                throw IOException("Unable to create ledger snapshot directory")
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
                    throw IOException("Ledger storage does not support atomic replacement", error)
                }
            } finally {
                if (temporary.exists()) {
                    temporary.delete()
                }
            }

            incomingRevision
        }

    fun load(): UnsentWindowLedgerLoadResult? = synchronized(persistenceLock) {
        readFromDisk()
    }

    private fun durableRevision(): Long = readFromDisk()?.let { decoded ->
        if (!decoded.isSuccess) {
            throw InvalidUnsentWindowLedgerSnapshotException()
        }
        decoded.persistenceRevision
    } ?: 0L

    private fun readFromDisk(): UnsentWindowLedgerLoadResult? {
        if (!file.exists()) {
            return null
        }
        return decodeUnsentWindowLedgerSnapshot(
            file.readText(StandardCharsets.UTF_8),
        )
    }

    companion object {
        private val locksByPath = ConcurrentHashMap<String, Any>()
        private const val MAX_QUARANTINED_SNAPSHOT_COUNT = 5
        private const val QUARANTINE_INFIX = ".corrupt-"

        private fun lockFor(path: String): Any = locksByPath.computeIfAbsent(path) { Any() }

        private fun canonicalPathKey(file: File): String =
            file.toPath().toAbsolutePath().normalize().toString()

        /**
         * Production startup policy for a snapshot whose shared decoder
         * rejects its bytes. Strict [UnsentWindowLedgerStore] construction
         * remains fail-closed; this opt-in path preserves the corrupt bytes
         * under a timestamped sibling name and opens an empty store at the
         * canonical path so future sensing can continue. Any other I/O error
         * (a permission error, the path being a directory, and so on) is not
         * treated as corruption and propagates unchanged, with nothing
         * quarantined — isolating this recovery to decode failures only is
         * the entire point: a transient read failure must never be mistaken
         * for corrupt content.
         */
        fun recoveringCorruptSnapshot(file: File): UnsentWindowLedgerStoreRecovery {
            val lock = lockFor(canonicalPathKey(file))
            synchronized(lock) {
                val store = UnsentWindowLedgerStore(file, validateOnConstruction = false)
                return try {
                    store.durableRevision()
                    UnsentWindowLedgerStoreRecovery(store = store, quarantinedFile = null)
                } catch (_: InvalidUnsentWindowLedgerSnapshotException) {
                    val quarantined = quarantineFile(file)
                    pruneOldQuarantinedSnapshots(file)
                    UnsentWindowLedgerStoreRecovery(store = store, quarantinedFile = quarantined)
                }
            }
        }

        private fun quarantineFile(file: File): File {
            val parent = requireNotNull(file.absoluteFile.parentFile)
            val quarantined = File(
                parent,
                "${file.name}$QUARANTINE_INFIX${System.currentTimeMillis()}-${UUID.randomUUID()}",
            )
            Files.move(file.toPath(), quarantined.toPath())
            return quarantined
        }

        /**
         * Quarantine files accumulate one per corruption event with nothing
         * that ever removes them. Cap how many survive: on a device that
         * corrupts repeatedly, this bounds worst-case disk usage to a small
         * constant while still keeping the most recent occurrences around
         * for diagnosis. Mirrors iOS's `maxQuarantinedSnapshotCount` of 5.
         */
        private fun pruneOldQuarantinedSnapshots(file: File) {
            val parent = file.absoluteFile.parentFile ?: return
            val prefix = "${file.name}$QUARANTINE_INFIX"
            val quarantined = (parent.listFiles() ?: return)
                .mapNotNull { candidate ->
                    quarantineTimestampMilliseconds(candidate.name, prefix)?.let { timestamp ->
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

        private fun quarantineTimestampMilliseconds(name: String, prefix: String): Long? {
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
}

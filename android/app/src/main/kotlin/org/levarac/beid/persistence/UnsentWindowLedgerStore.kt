package org.levarac.beid.persistence

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.ConcurrentHashMap
import org.levarac.beid.shared.report.UnsentWindowLedgerLoadResult
import org.levarac.beid.shared.report.UnsentWindowLedgerTransition
import org.levarac.beid.shared.report.decodeUnsentWindowLedgerSnapshot

/**
 * Native storage boundary for the shared ledger's already-encoded snapshot.
 *
 * This class decides only filesystem ordering and atomic replacement. Ledger
 * transitions, snapshot syntax, and report eligibility remain in `shared`.
 * Production wiring is deferred to beid#121, where Android persistence and
 * listing first consume the shared snapshot codec.
 */
internal class UnsentWindowLedgerStore(
    private val file: File,
) {
    private val persistenceLock = lockFor(
        file.toPath().toAbsolutePath().normalize().toString(),
    )

    init {
        synchronized(persistenceLock) {
            durableRevision()
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
            throw IOException("Invalid existing unsent-window ledger snapshot")
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

    private companion object {
        val locksByPath = ConcurrentHashMap<String, Any>()

        fun lockFor(path: String): Any = locksByPath.computeIfAbsent(path) { Any() }
    }
}

package org.levarac.beid.persistence

import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.levarac.beid.shared.report.createUnsentWindowLedger
import org.levarac.beid.shared.report.openUnsentWindow

class UnsentWindowLedgerStoreRecoveryTest {
    @Test
    fun corruptExistingSnapshotIsQuarantinedAndFreshStoreWorks() {
        val directory = Files.createTempDirectory("beid-ledger-recovery-corrupt").toFile()
        try {
            val file = directory.resolve("ledger.snapshot")
            file.writeText("not a valid snapshot", StandardCharsets.UTF_8)

            val recovery = UnsentWindowLedgerStore.recoveringCorruptSnapshot(file)
            val quarantined = assertNotNull(recovery.quarantinedFile)
            assertTrue(quarantined.exists())
            assertEquals("not a valid snapshot", quarantined.readText(StandardCharsets.UTF_8))
            assertFalse(file.exists())

            val ledger = assertNotNull(
                createUnsentWindowLedger(
                    ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
                ).ledger,
            )
            val opened = openUnsentWindow(ledger, "window-1")
            assertEquals(1L, recovery.store.persist(opened))

            val reloaded = assertNotNull(recovery.store.load())
            assertTrue(reloaded.isSuccess)
            assertEquals(1L, reloaded.persistenceRevision)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun validExistingSnapshotOpensNormallyWithoutQuarantine() {
        val directory = Files.createTempDirectory("beid-ledger-recovery-valid").toFile()
        try {
            val file = directory.resolve("ledger.snapshot")
            val ledger = assertNotNull(
                createUnsentWindowLedger(
                    ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
                ).ledger,
            )
            val opened = openUnsentWindow(ledger, "window-1")
            UnsentWindowLedgerStore(file).persist(opened)

            val recovery = UnsentWindowLedgerStore.recoveringCorruptSnapshot(file)
            assertNull(recovery.quarantinedFile)
            val loaded = assertNotNull(recovery.store.load())
            assertEquals(1L, loaded.persistenceRevision)
            assertTrue(directory.listFiles()!!.none { it.name.contains("corrupt") })
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun nonDecodeIoErrorPropagatesAndDoesNotQuarantine() {
        val directory = Files.createTempDirectory("beid-ledger-recovery-ioerror").toFile()
        try {
            val file = directory.resolve("ledger.snapshot")
            assertTrue(file.mkdir())

            val error = assertFailsWith<IOException> {
                UnsentWindowLedgerStore.recoveringCorruptSnapshot(file)
            }
            assertFalse(error is InvalidUnsentWindowLedgerSnapshotException)
            assertTrue(file.isDirectory)
            assertTrue(directory.listFiles()!!.none { it.name.contains("corrupt") })
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun plainConstructorStillThrowsOnCorruptSnapshot() {
        val directory = Files.createTempDirectory("beid-ledger-recovery-strict").toFile()
        try {
            val file = directory.resolve("ledger.snapshot")
            file.writeText("not a valid snapshot", StandardCharsets.UTF_8)

            assertFailsWith<InvalidUnsentWindowLedgerSnapshotException> {
                UnsentWindowLedgerStore(file)
            }
            assertTrue(file.exists())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun quarantineCountIsBoundedToTheMostRecentFive() {
        val directory = Files.createTempDirectory("beid-ledger-recovery-bound").toFile()
        try {
            val file = directory.resolve("ledger.snapshot")
            val preexisting = (1..5).map { index ->
                val quarantineFile = directory.resolve("${file.name}.corrupt-${1_000L + index}-seed-$index")
                quarantineFile.writeText("seed-$index")
                quarantineFile
            }

            file.writeText("not a valid snapshot", StandardCharsets.UTF_8)
            val recovery = UnsentWindowLedgerStore.recoveringCorruptSnapshot(file)
            val newest = assertNotNull(recovery.quarantinedFile)

            val survivors = directory.listFiles { candidate -> candidate.name.contains(".corrupt-") }!!
            assertEquals(5, survivors.size)
            assertTrue(survivors.contains(newest))
            assertFalse(survivors.contains(preexisting.first()))
        } finally {
            directory.deleteRecursively()
        }
    }
}

package org.levarac.beid.persistence

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import org.levarac.beid.shared.report.closeUnsentWindow
import org.levarac.beid.shared.report.createUnsentWindowLedger
import org.levarac.beid.shared.report.encodeUnsentWindowLedgerSnapshot
import org.levarac.beid.shared.report.openUnsentWindow
import org.levarac.beid.shared.report.prepareNextUnsentWindowSubmission
import org.levarac.beid.shared.report.resumeUnsentWindowSubmissionAfterRestore

class UnsentWindowLedgerStoreTest {
    @Test
    fun aLateOlderWriteFromAnotherStoreInstanceCannotReplaceANewerSnapshot() {
        val directory = Files.createTempDirectory("beid-ledger-multi-store").toFile()
        try {
            val file = directory.resolve("ledger.snapshot")
            val olderStore = UnsentWindowLedgerStore(file)
            val newerStore = UnsentWindowLedgerStore(file)
            val ledger = assertNotNull(
                createUnsentWindowLedger(
                    ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
                ).ledger,
            )
            val opened = openUnsentWindow(ledger, "window-1")
            val closed = closeUnsentWindow(
                ledger = opened.ledger,
                windowId = "window-1",
                persistedObservationReference = "observation-1",
            )

            assertEquals(2L, newerStore.persist(closed))
            assertEquals(2L, olderStore.persist(opened))
            assertEquals(
                2L,
                assertNotNull(UnsentWindowLedgerStore(file).load()).persistenceRevision,
            )
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun aLateOlderWriteCannotReplaceANewerDurableSnapshot() {
        val directory = Files.createTempDirectory("beid-ledger-store").toFile()
        try {
            val file = directory.resolve("ledger.snapshot")
            val store = UnsentWindowLedgerStore(file)
            val ledger = assertNotNull(
                createUnsentWindowLedger(
                    ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
                ).ledger,
            )
            val opened = openUnsentWindow(ledger, "window-1")
            val closed = closeUnsentWindow(
                ledger = opened.ledger,
                windowId = "window-1",
                persistedObservationReference = "observation-1",
            )

            assertEquals(2L, store.persist(closed))
            assertEquals(2L, store.persist(opened))
            assertEquals(
                assertNotNull(closed.snapshotText),
                file.readText(StandardCharsets.UTF_8),
            )

            val relaunchedStore = UnsentWindowLedgerStore(file)
            val restored = assertNotNull(relaunchedStore.load())
            assertTrue(restored.isSuccess)
            assertEquals(2L, restored.persistenceRevision)
            assertEquals(
                closed.snapshotText,
                encodeUnsentWindowLedgerSnapshot(assertNotNull(restored.ledger)),
            )
            assertTrue(
                file.readBytes().contentEquals(
                    assertNotNull(closed.snapshotText).encodeToByteArray(),
                ),
            )
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun killRelaunchAndPortableTransferRestorePendingThenTheSameInFlightSubmission() {
        val directory = Files.createTempDirectory("beid-ledger-portable").toFile()
        try {
            val ledgerFile = directory.resolve("ledger.snapshot")
            val observationFile = directory.resolve("observation-1.chunk")
            observationFile.writeBytes(byteArrayOf(0x01, 0x02, 0x03))

            val initialStore = UnsentWindowLedgerStore(ledgerFile)
            val empty = assertNotNull(
                createUnsentWindowLedger(
                    ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
                ).ledger,
            )
            val opened = openUnsentWindow(empty, "window-1")
            val closed = closeUnsentWindow(
                ledger = opened.ledger,
                windowId = "window-1",
                persistedObservationReference = observationFile.name,
            )
            assertTrue(observationFile.exists())
            initialStore.persist(closed)

            val pendingAfterRelaunch = assertNotNull(
                UnsentWindowLedgerStore(ledgerFile).load(),
            )
            assertEquals(2L, pendingAfterRelaunch.persistenceRevision)
            val prepared = prepareNextUnsentWindowSubmission(
                ledger = assertNotNull(pendingAfterRelaunch.ledger),
                maximumWindowCount = 10,
                nowEpochMilliseconds = 0L,
            )
            UnsentWindowLedgerStore(ledgerFile).persist(prepared)

            val inFlightAfterRelaunch = assertNotNull(
                UnsentWindowLedgerStore(ledgerFile).load(),
            )
            val resumed = assertNotNull(
                resumeUnsentWindowSubmissionAfterRestore(
                    assertNotNull(inFlightAfterRelaunch.ledger),
                ).submission,
            )
            assertEquals(
                "000102030405060708090a0b0c0d0e0f0000000000000001",
                resumed.submissionKey,
            )
            assertEquals("window-1", resumed.windowIdAt(0))
            assertEquals(observationFile.name, resumed.observationReferenceAt(0))
            assertTrue(
                ledgerFile.readBytes().contentEquals(
                    assertNotNull(prepared.snapshotText).encodeToByteArray(),
                ),
            )

            val portableFile = directory.resolve("server-restored.snapshot")
            Files.copy(
                ledgerFile.toPath(),
                portableFile.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
            )
            val portable = assertNotNull(UnsentWindowLedgerStore(portableFile).load())
            val portableSubmission = assertNotNull(
                resumeUnsentWindowSubmissionAfterRestore(
                    assertNotNull(portable.ledger),
                ).submission,
            )
            assertEquals(resumed.submissionKey, portableSubmission.submissionKey)
            assertEquals(resumed.windowIdAt(0), portableSubmission.windowIdAt(0))
            assertEquals(
                resumed.observationReferenceAt(0),
                portableSubmission.observationReferenceAt(0),
            )
        } finally {
            directory.deleteRecursively()
        }
    }
}

package org.levarac.beid.persistence

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.levarac.beid.shared.report.addPersistedUnsentWindowObservationForRecovery
import org.levarac.beid.shared.report.closeUnsentWindow
import org.levarac.beid.shared.report.confirmUnsentWindowLedgerPersistence
import org.levarac.beid.shared.report.createUnsentWindowLedger
import org.levarac.beid.shared.report.createUnsentWindowObservationRecoveryInput
import org.levarac.beid.shared.report.encodeUnsentWindowLedgerSnapshot
import org.levarac.beid.shared.report.openUnsentWindow
import org.levarac.beid.shared.report.prepareNextUnsentWindowSubmission
import org.levarac.beid.shared.report.reconcileUnsentWindowLedgerAfterRelaunch
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

    @Test
    fun foregroundEndBackgroundAndProcessStartOrderingSubmitsWindowAtMostOnce() {
        val directory = Files.createTempDirectory("beid-ledger-bg-report").toFile()
        try {
            val ledgerFile = directory.resolve("ledger.snapshot")
            val store = UnsentWindowLedgerStore(ledgerFile)
            val ledger = assertNotNull(
                createUnsentWindowLedger(
                    ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
                ).ledger,
            )

            // 1. Detection in foreground opens window
            val opened = openUnsentWindow(ledger, "window-1")
            var currentLedger = confirmUnsentWindowLedgerPersistence(
                ledger = opened.ledger,
                revision = store.persist(opened),
            ).ledger!!

            // 2. Foreground-end (session stop or window end) closes window
            val foregroundClosed = closeUnsentWindow(
                ledger = currentLedger,
                windowId = "window-1",
                persistedObservationReference = "observation-1",
            )
            assertTrue(foregroundClosed.changed)
            currentLedger = confirmUnsentWindowLedgerPersistence(
                ledger = foregroundClosed.ledger,
                revision = store.persist(foregroundClosed),
            ).ledger!!

            // 3. Background transition / ON_STOP: attempt checkpoint
            // Since window is already closed, duplicate close is idempotent and no-ops (changed == false)
            val backgroundClosed = closeUnsentWindow(
                ledger = currentLedger,
                windowId = "window-1",
                persistedObservationReference = "observation-1",
            )
            assertTrue(backgroundClosed.isSuccess)
            assertFalse(backgroundClosed.changed)

            // 4. Cold launch / process start: fresh store load and recovery
            val relaunchedStore = UnsentWindowLedgerStore(ledgerFile)
            val reloaded = assertNotNull(relaunchedStore.load())
            assertTrue(reloaded.isSuccess)

            val recoveryInput = createUnsentWindowObservationRecoveryInput()
            assertTrue(
                addPersistedUnsentWindowObservationForRecovery(
                    recoveryInput = recoveryInput,
                    windowId = "window-1",
                    persistedObservationReference = "observation-1",
                )
            )
            val reconciled = reconcileUnsentWindowLedgerAfterRelaunch(
                ledger = assertNotNull(reloaded.ledger),
                recoveryInput = recoveryInput,
            )
            assertTrue(reconciled.isSuccess)
            val restoredLedger = if (reconciled.changed) {
                confirmUnsentWindowLedgerPersistence(
                    ledger = reconciled.ledger,
                    revision = relaunchedStore.persist(reconciled),
                ).ledger!!
            } else {
                reconciled.ledger
            }

            // 5. Prepare submission: exactly one submission must be produced
            val prepared = prepareNextUnsentWindowSubmission(
                ledger = restoredLedger,
                maximumWindowCount = 10,
                nowEpochMilliseconds = 0L,
            )
            assertTrue(prepared.isSuccess)
            assertTrue(prepared.changed)

            // Persist the prepared submission (now IN_FLIGHT) and confirm
            val confirmed = confirmUnsentWindowLedgerPersistence(
                ledger = prepared.ledger,
                revision = relaunchedStore.persist(prepared),
            )
            assertTrue(confirmed.isSuccess)
            val submission = assertNotNull(confirmed.submission)
            assertEquals(1, submission.windowCount)
            assertEquals("window-1", submission.windowIdAt(0))
            assertEquals("observation-1", submission.observationReferenceAt(0))
            val inFlightLedger = confirmed.ledger

            // 6. Idempotency: subsequent submission preparation while IN_FLIGHT produces NO duplicate submission
            val duplicatePrepare = prepareNextUnsentWindowSubmission(
                ledger = inFlightLedger,
                maximumWindowCount = 10,
                nowEpochMilliseconds = 0L,
            )
            assertTrue(duplicatePrepare.isSuccess)
            assertFalse(duplicatePrepare.changed)
            assertNull(duplicatePrepare.submission)

            // Further background/stop/launch attempts also do not create duplicate submissions
            val postBackgroundClose = closeUnsentWindow(
                ledger = inFlightLedger,
                windowId = "window-1",
                persistedObservationReference = "observation-1",
            )
            assertTrue(postBackgroundClose.isSuccess)
            assertFalse(postBackgroundClose.changed)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun backgroundBeforeForegroundEndAndProcessStartOrderingSubmitsWindowAtMostOnce() {
        val directory = Files.createTempDirectory("beid-ledger-bg-first").toFile()
        try {
            val ledgerFile = directory.resolve("ledger.snapshot")
            val store = UnsentWindowLedgerStore(ledgerFile)
            val ledger = assertNotNull(
                createUnsentWindowLedger(
                    ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
                ).ledger,
            )

            // 1. Detection in foreground opens window
            val opened = openUnsentWindow(ledger, "window-1")
            var currentLedger = confirmUnsentWindowLedgerPersistence(
                ledger = opened.ledger,
                revision = store.persist(opened),
            ).ledger!!

            // 2. Background transition / ON_STOP closes open window
            val backgroundClosed = closeUnsentWindow(
                ledger = currentLedger,
                windowId = "window-1",
                persistedObservationReference = "observation-1",
            )
            assertTrue(backgroundClosed.changed)
            currentLedger = confirmUnsentWindowLedgerPersistence(
                ledger = backgroundClosed.ledger,
                revision = store.persist(backgroundClosed),
            ).ledger!!

            // 3. Foreground stop afterwards: already closed window is skipped (changed == false)
            val stopClosed = closeUnsentWindow(
                ledger = currentLedger,
                windowId = "window-1",
                persistedObservationReference = "observation-1",
            )
            assertTrue(stopClosed.isSuccess)
            assertFalse(stopClosed.changed)

            // 4. Process start / cold launch
            val relaunchedStore = UnsentWindowLedgerStore(ledgerFile)
            val reloaded = assertNotNull(relaunchedStore.load())
            val prepared = prepareNextUnsentWindowSubmission(
                ledger = assertNotNull(reloaded.ledger),
                maximumWindowCount = 10,
                nowEpochMilliseconds = 0L,
            )
            assertTrue(prepared.changed)
            val confirmed = confirmUnsentWindowLedgerPersistence(
                ledger = prepared.ledger,
                revision = relaunchedStore.persist(prepared),
            )
            assertTrue(confirmed.isSuccess)
            val submission = assertNotNull(confirmed.submission)
            assertEquals(1, submission.windowCount)
            assertEquals("window-1", submission.windowIdAt(0))
            assertEquals("observation-1", submission.observationReferenceAt(0))
        } finally {
            directory.deleteRecursively()
        }
    }
}
